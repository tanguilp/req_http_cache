defmodule ReqHTTPCache.MixProject do
  use Mix.Project

  def project do
    [
      app: :req_http_cache,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:bypass, "~> 2.1", only: :test},
      {:dialyxir, "~> 1.0", only: :dev, runtime: false},
      {:ex_doc, "~> 0.24", only: :dev, runtime: false},
      {:http_cache, "~> 0.3.0"},
      {:req, github: "wojtekmach/req"}
    ]
  end
end
