defmodule ReqHTTPCacheTest do
  use ExUnit.Case

  @http_cache_opts %{type: :private, store: :http_cache_store_process}
  @test_url "http://no-exist-domain-adsxikfgjs.com"
  @test_req {"GET", @test_url, [], ""}
  @test_resp {200, [], "Some content"}

  setup do
    client = Req.new(url: @test_url, retry: false) |> ReqHTTPCache.attach(@http_cache_opts)
    [client: client]
  end

  describe "attach/2" do
    test "returns cached response", c do
      {:ok, _} = :http_cache.cache(@test_req, @test_resp, @http_cache_opts)

      cached_response = Req.get!(c.client)

      assert cached_response.status == 200
      assert cached_response.body == "Some content"
      assert [_] = cached_response.headers["age"]
    end

    test "returns cached response stored in file", c do
      :http_cache_store_process.save_in_file()

      {:ok, _} = :http_cache.cache(@test_req, @test_resp, @http_cache_opts)

      cached_response = Req.get!(c.client)

      assert cached_response.status == 200
      assert cached_response.body == "Some content"
      assert [_] = cached_response.headers["age"]
    end

    test "returns cached response stored in file with range", c do
      :http_cache_store_process.save_in_file()

      {:ok, _} = :http_cache.cache(@test_req, @test_resp, @http_cache_opts)

      cached_response = Req.get!(c.client, headers: [{"range", "bytes=0-3"}])

      assert cached_response.status == 206
      assert cached_response.body == "Some"
      assert [_] = cached_response.headers["age"]
    end

    test "returns cached response when cache is disconnected", c do
      {:ok, _} =
        :http_cache.cache(
          @test_req,
          {200, [{"cache-control", "max-age=0"}], "Some content"},
          @http_cache_opts
        )

      cached_response = Req.get!(c.client, adapter: &unreachable_adapter/1)

      assert cached_response.status == 200
      assert cached_response.body == "Some content"
      assert [_] = cached_response.headers["age"]
    end

    for http_status <- [500, 502, 503, 504] do
      test "returns cached response when origin returns a #{http_status} error", c do
        {:ok, _} =
          :http_cache.cache(
            @test_req,
            {200, [{"cache-control", "max-age=0, stale-if-error=600"}], "Some content"},
            @http_cache_opts
          )

        cached_response =
          Req.get!(c.client, adapter: &origin_error_adapter(&1, unquote(http_status)))

        assert cached_response.status == 200
        assert cached_response.body == "Some content"
        assert [_] = cached_response.headers["age"]
      end
    end

    test "raises when store option is missing", _c do
      assert_raise RuntimeError, fn -> Req.new(url: @test_url) |> ReqHTTPCache.attach([]) end
    end

    test "raises if body is not a binary or an IOlist", c do
      assert_raise ArgumentError, fn -> Req.get!(c.client, body: %{"some" => "json"}) end
    end

    test "adds etag validator when validating response", c do
      resp = {200, [{"etag", "some_etag"}, {"cache-control", "max-age=0"}], "Some content"}
      {:ok, _} = :http_cache.cache(@test_req, resp, @http_cache_opts)

      # FIXME: is there a better way than returning request headers in the body through an adapter?
      request_headers =
        Req.get!(c.client, adapter: &revalidate_adapter/1, raw: true).body |> Jason.decode!()

      assert request_headers["if-none-match"] == ["some_etag"]
    end

    test "adds last-modified validator when validating response", c do
      resp =
        {200,
         [{"last-modified", "Wed, 21 Oct 2015 07:28:00 GMT"}, {"cache-control", "max-age=0"}],
         "Some content"}

      {:ok, _} = :http_cache.cache(@test_req, resp, @http_cache_opts)

      # FIXME: is there a better way than returning request headers in the body through an adapter?
      request_headers =
        Req.get!(c.client, adapter: &revalidate_adapter/1, raw: true).body |> Jason.decode!()

      assert request_headers["if-modified-since"] == ["Wed, 21 Oct 2015 07:28:00 GMT"]
    end
  end

  defp unreachable_adapter(request) do
    {request, %Mint.TransportError{reason: :timeout}}
  end

  defp origin_error_adapter(request, http_error_status) do
    {request, %Req.Response{status: http_error_status, body: "Oups!"}}
  end

  defp revalidate_adapter(request) do
    response = %Req.Response{
      status: 200,
      headers: %{"content-type" => ["application/json"]},
      body: Jason.encode!(request.headers)
    }

    {request, response}
  end
end
