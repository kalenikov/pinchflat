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

    case :httpc.request(:get, {url, headers}, http_opts, request_opts) do
      {:ok, {{_version, 200, _reason_phrase}, _headers, body}} ->
        {:ok, to_string(body)}

      {:ok, {{_version, status_code, reason_phrase}, _headers, _body}} ->
        {:error, "HTTP request failed with status code #{status_code}: #{reason_phrase}"}

      {:error, reason} ->
        {:error, "HTTP request failed: #{reason}"}
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
end
