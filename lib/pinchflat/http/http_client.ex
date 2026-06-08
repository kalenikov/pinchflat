defmodule Pinchflat.HTTP.HTTPClient do
  @moduledoc """
  This module provides a simple interface for making HTTP requests.

  Made to be easily swappable with other HTTP clients. If you need more complexity
  or security, check out HTTPoison or Mint.
  """

  alias Pinchflat.HTTP.HTTPBehaviour

  @behaviour HTTPBehaviour

  @default_http_options [
    timeout: 30_000,
    connect_timeout: 10_000
  ]

  @empty_proxy {{~c"", 0}, []}

  @doc """
  Makes a GET request to the given URL and returns the response.

  NOTE: I can't really test this with Mox and I can't think of a way to test this
  that isn't ultimately redundant. I'm just going to leave it untested for now and
  focus more on testing the consumers of this module.

  Returns {:ok, String.t()} | {:error, String.t()}
  """
  @impl HTTPBehaviour
  def get(url, headers \\ [], opts \\ []) do
    headers = parse_headers(headers)
    {http_opts, request_opts} = split_options(opts)
    set_proxy_options(url)

    case :httpc.request(:get, {url, headers}, http_opts, request_opts) do
      {:ok, {{_version, 200, _reason_phrase}, _headers, body}} ->
        {:ok, to_string(body)}

      {:ok, {{_version, status_code, reason_phrase}, _headers, _body}} ->
        {:error, "HTTP request failed with status code #{status_code}: #{reason_phrase}"}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp parse_headers(headers) do
    Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
  end

  defp split_options(opts) do
    # LOCAL PATCH: avoid indefinitely stuck Oban jobs on external HTTP calls.
    {http_opts, request_opts} = Keyword.split(opts, [:timeout, :connect_timeout])

    {Keyword.merge(@default_http_options, http_opts), request_opts}
  end

  defp set_proxy_options(url) do
    proxy =
      url
      |> URI.parse()
      |> proxy_for_uri()

    :httpc.set_options(proxy: proxy || @empty_proxy)
  end

  defp proxy_for_uri(%URI{host: host} = uri) when is_binary(host) do
    if no_proxy?(host) do
      nil
    else
      uri
      |> proxy_env()
      |> parse_proxy()
    end
  end

  defp proxy_for_uri(_uri), do: nil

  defp proxy_env(%URI{scheme: "https"}) do
    System.get_env("HTTPS_PROXY") || System.get_env("https_proxy") ||
      System.get_env("HTTP_PROXY") || System.get_env("http_proxy")
  end

  defp proxy_env(%URI{scheme: "http"}) do
    System.get_env("HTTP_PROXY") || System.get_env("http_proxy")
  end

  defp proxy_env(_uri), do: nil

  defp parse_proxy(nil), do: nil
  defp parse_proxy(""), do: nil

  defp parse_proxy(proxy_url) do
    case URI.parse(proxy_url) do
      %URI{scheme: "http", host: host, port: port} when is_binary(host) and is_integer(port) ->
        {{to_charlist(host), port}, no_proxy_hosts()}

      _unsupported ->
        nil
    end
  end

  defp no_proxy?(host) do
    host = String.downcase(host)

    no_proxy_entries()
    |> Enum.any?(fn
      "*" -> true
      "." <> suffix -> String.ends_with?(host, "." <> String.downcase(suffix))
      entry -> host == String.downcase(entry)
    end)
  end

  defp no_proxy_hosts do
    Enum.map(no_proxy_entries(), &to_charlist/1)
  end

  defp no_proxy_entries do
    "NO_PROXY"
    |> System.get_env(System.get_env("no_proxy", ""))
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
