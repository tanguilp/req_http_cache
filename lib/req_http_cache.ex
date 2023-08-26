defmodule ReqHTTPCache do
  @moduledoc """
  Documentation for `ReqHTTPCache`.
  """

  @default_opts %{auto_accept_encoding: true, auto_compress: true, type: :private}
  @stale_if_error_status [500, 502, 503, 504]

  @spec attach(Req.Request.t(), :http_cache.opts()) :: Req.Request.t()
  def attach(%Req.Request{} = request, %{} = http_cache_opts) do
    http_cache_opts[:store] || raise("Missing `store` http_cache option")

    http_cache_opts =
      @default_opts
      |> Map.merge(http_cache_opts)
      |> Map.put(:request_time, now())

    request
    |> Req.Request.register_options([:http_cache])
    |> Req.Request.merge_options(http_cache: Enum.into(http_cache_opts, %{}))
    |> Req.Request.append_request_steps(read_from_http_cache: &read_from_http_cache/1)
    |> Req.Request.append_response_steps(cache_response: &cache_response/1)
    |> Req.Request.append_error_steps(get_stale_from_cache: &get_stale_from_cache/1)
  end

  defp read_from_http_cache(request) do
    http_cache_opts = request.options.http_cache
    http_cache_request = to_http_cache_request(request)

    case :http_cache.get(http_cache_request, http_cache_opts) do
      {:fresh, _} = http_cache_get_response ->
        return_cached_response(request, http_cache_get_response, http_cache_opts)

      {:stale, _} = http_cache_get_response ->
        return_cached_response(request, http_cache_get_response, http_cache_opts)

      {:must_revalidate, _} = http_cache_get_response ->
        :http_cache.notify_downloading(http_cache_request, self(), http_cache_opts)

        revalidate(request, http_cache_get_response)

      :miss ->
        :telemetry.execute([:req_http_cache, :miss], %{})

        :http_cache.notify_downloading(http_cache_request, self(), http_cache_opts)

        http_cache_opts = Map.put(http_cache_opts, :request_time, now())

        Req.Request.merge_options(request, http_cache: http_cache_opts)
    end
  end

  defp revalidate(
         request,
         {:must_revalidate, {_, {_, cached_headers, _} = http_cache_revalidated_response}}
       ) do
    request
    |> add_validator(cached_headers, "last-modified", "if-modified-since")
    |> add_validator(cached_headers, "etag", "if-none-match")
    |> Req.Request.put_private(:http_cache_revalidated_response, http_cache_revalidated_response)
  end

  defp cache_response({request, %Req.Response{status: 304} = response}) do
    http_cache_opts = request.options.http_cache

    http_cache_revalidated_response =
      Req.Request.get_private(response, :http_cache_revalidated_response)

    :telemetry.execute([:tesla_http_cache, :hit], %{}, %{freshness: :revalidated})

    case :http_cache.cache(
           to_http_cache_request(request),
           to_http_cache_response(response),
           http_cache_revalidated_response,
           http_cache_opts
         ) do
      {:ok, http_cache_response} ->
        {request, to_req_response(http_cache_response)}

      :not_cacheable ->
        {request, response}
    end
  end

  defp cache_response({request, %Req.Response{status: status} = response})
       when status in @stale_if_error_status do
    if Req.Request.get_private(request, :returned_from_cache) do
      {request, response}
    else
      http_cache_opts = Map.put(request.options.http_cache, :allow_stale_if_error, true)
      http_cache_request = to_http_cache_request(request)
      http_cache_response = to_http_cache_response(response)

      # We always cache even responses we do know are uncacheable because this can
      # have side effects, such as invalidating or reseting request collapsing
      :http_cache.cache(http_cache_request, http_cache_response, http_cache_opts)

      case :http_cache.get(http_cache_request, http_cache_opts) do
        {:fresh, _} = http_cache_resp ->
          return_cached_response(request, http_cache_resp, http_cache_opts)

        {:stale, _} = http_cache_resp ->
          return_cached_response(request, http_cache_resp, http_cache_opts)

        _ ->
          {request, response}
      end
    end
  end

  defp cache_response({request, %Req.Response{} = response}) do
    if Req.Request.get_private(request, :returned_from_cache) do
      {request, response}
    else
      http_cache_opts = request.options.http_cache
      http_cache_request = to_http_cache_request(request)
      http_cache_response = to_http_cache_response(response)

      case :http_cache.cache(http_cache_request, http_cache_response, http_cache_opts) do
        {:ok, http_cache_response} ->
          {request, to_req_response(http_cache_response)}

        :not_cacheable ->
          {request, response}
      end
    end
  end

  defp get_stale_from_cache({request, %Mint.TransportError{} = error}) do
    http_cache_opts = Map.put(request.options.http_cache, :origin_unreachable, true)
    http_cache_request = to_http_cache_request(request)

    :http_cache.cache(http_cache_request, {504, [], ""}, http_cache_opts)

    case :http_cache.get(http_cache_request, http_cache_opts) do
      {:fresh, _} = http_cache_resp ->
        return_cached_response(request, http_cache_resp, http_cache_opts)

      {:stale, _} = http_cache_resp ->
        return_cached_response(request, http_cache_resp, http_cache_opts)

      _ ->
        {request, error}
    end
  end

  defp get_stale_from_cache({request, error}) do
    {request, error}
  end

  defp return_cached_response(
         request,
         {freshness, {response_ref, http_cache_response}},
         http_cache_opts
       ) do
    :http_cache.notify_response_used(response_ref, http_cache_opts)
    :telemetry.execute([:req_http_cache, :hit], %{}, %{freshness: freshness})

    request = Req.Request.put_private(request, :returned_from_cache, true)

    {request, to_req_response(http_cache_response)}
  end

  defp to_http_cache_request(request) do
    {
      request.method |> to_string() |> String.upcase(),
      request.url |> URI.to_string(),
      to_http_cache_headers(request.headers),
      (request.body || "") |> :erlang.iolist_to_binary()
    }
  end

  defp to_http_cache_response(%Req.Response{body: body} = response) when is_binary(body) do
    {response.status, to_http_cache_headers(response.headers), response.body}
  end

  defp to_req_response({status, resp_headers, {:sendfile, 0, :all, path}}) do
    to_req_response({status, resp_headers, File.read!(path)})
  end

  defp to_req_response({status, resp_headers, {:sendfile, offset, length, path}}) do
    file = File.open!(path, [:read, :raw, :binary])

    try do
      {:ok, content} = :file.pread(file, offset, length)
      to_req_response({status, resp_headers, content})
    after
      File.close(file)
    end
  end

  defp to_req_response({status, resp_headers, resp_body}) when is_binary(resp_body) do
    Req.Response.new(status: status, headers: resp_headers, body: resp_body)
  end

  defp to_http_cache_headers(req_headers) do
    for {header_name, header_values} <- req_headers,
        header_value <- header_values,
        do: {header_name, header_value}
  end

  defp add_validator(request, cached_headers, validator, condition_header) do
    cached_headers
    |> Enum.find(fn {header_name, _} -> String.downcase(header_name) == validator end)
    |> case do
      {_, header_value} ->
        Req.Request.put_header(request, condition_header, header_value)

      nil ->
        request
    end
  end

  defp now(), do: :os.system_time(:second)
end
