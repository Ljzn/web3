defmodule Web3.HTTP do
  @moduledoc """
  JSONRPC over HTTP
  """

  require Logger

  import Web3, only: [to_integer: 1]

  @doc """
  Sends JSONRPC request encoded as `t:iodata/0` to `url` with `options`

  ## Examples

    iex> request = %{jsonrpc: "2.0", method: "eth_getBalance", params: ["0x1B93C60808449eF4B675caFAca8e7b40999f3fc5", "latest"], id: 1}
    iex> options = [url: "https://bsc-dataseed4.ninicoin.io/", http: Web3.HTTP.HTTPoison, http_options: [recv_timeout: 60_000, timeout: 60_000, hackney: [pool: :web3]]]
    iex> Web3.HTTP.json_rpc(request, options)
    {:ok, %{}}

    iex> request = [%{id: 1, jsonrpc: "2.0", method: "eth_getBalance", params: ["0x1B93C60808449eF4B675caFAca8e7b40999f3fc5", "latest"]}, %{id: 2, jsonrpc: "2.0", method: "eth_blockNumber", params: []}]
    iex> options = [url: "https://bsc-dataseed4.ninicoin.io/", http: Web3.HTTP.HTTPoison, http_options: [recv_timeout: 60_000, timeout: 60_000, hackney: [pool: :web3]]]
    iex> Web3.HTTP.json_rpc(request, options)
    {:ok, [%{id: 1, result: ""}, %{id: 2, result: ""}]}

  """
  @callback json_rpc(url :: String.t(), json :: iodata(), options :: term()) ::
              {:ok, %{body: body :: String.t(), status_code: status_code :: pos_integer()}}
              | {:error, reason :: term}

  def json_rpc(%{method: _method} = request, options) when is_map(request) do
    json = encode_json(request)
    http = Keyword.fetch!(options, :http)
    url = Keyword.fetch!(options, :rpc_endpoint)
    http_options = Keyword.fetch!(options, :http_options)

    with {:ok, %{body: body, status_code: code}} <- http.json_rpc(url, json, http_options),
         {:ok, json} <- decode_json(request: [url: url, body: json], response: [status_code: code, body: body]) do
      handle_response(json, code)
    end
  end

  def json_rpc(batch_request, options) when is_list(batch_request) do
    chunked_json_rpc([batch_request], options, [])
  end

  defp chunked_json_rpc([], _options, decoded_response_bodies) when is_list(decoded_response_bodies) do
    list =
      decoded_response_bodies
      |> Enum.reverse()
      |> List.flatten()
      |> Enum.map(&standardize_response/1)

    {:ok, list}
  end

  # JSONRPC 2.0 standard says that an empty batch (`[]`) returns an empty response (`""`), but an empty response isn't
  # valid JSON, so instead act like it returns an empty list (`[]`)
  defp chunked_json_rpc([[] | tail], options, decoded_response_bodies) do
    chunked_json_rpc(tail, options, decoded_response_bodies)
  end

  defp chunked_json_rpc([[%{method: _method} | _] = batch | tail] = chunks, options, decoded_response_bodies) when is_list(tail) and is_list(decoded_response_bodies) do
    http = Keyword.fetch!(options, :http)
    url = Keyword.fetch!(options, :rpc_endpoint)
    http_options = Keyword.fetch!(options, :http_options)

    json = encode_json(batch)

    case http.json_rpc(url, json, http_options) do
      {:ok, %{status_code: status_code} = response} when status_code in [413, 504] ->
        rechunk_json_rpc(chunks, options, response, decoded_response_bodies)

      {:ok, %{body: body, status_code: status_code}} ->
        with {:ok, decoded_body} <-
               decode_json(
                 request: [url: url, body: json],
                 response: [status_code: status_code, body: body]
               ) do
          chunked_json_rpc(tail, options, [decoded_body | decoded_response_bodies])
        end

      {:error, :timeout} ->
        rechunk_json_rpc(chunks, options, :timeout, decoded_response_bodies)

      {:error, _} = error ->
        error
    end
  end

  defp rechunk_json_rpc([batch | tail], options, response, decoded_response_bodies) do
    case length(batch) do
      # it can't be made any smaller
      1 ->
        Logger.error(fn ->
          "413 Request Entity Too Large returned from single request batch.  Cannot shrink batch further."
        end)

        {:error, response}

      batch_size ->
        split_size = div(batch_size, 2)
        {first_chunk, second_chunk} = Enum.split(batch, split_size)
        new_chunks = [first_chunk, second_chunk | tail]
        chunked_json_rpc(new_chunks, options, decoded_response_bodies)
    end
  end

  defp encode_json(data), do: Jason.encode_to_iodata!(data)

  defp decode_json(named_arguments) when is_list(named_arguments) do
    response = Keyword.fetch!(named_arguments, :response)
    response_body = Keyword.fetch!(response, :body)

    with {:error, _} <- Jason.decode(response_body, keys: :atoms) do
      case Keyword.fetch!(response, :status_code) do
        # CloudFlare protected server return HTML errors for 502, so the JSON decode will fail
        502 ->
          request_url =
            named_arguments
            |> Keyword.fetch!(:request)
            |> Keyword.fetch!(:url)

          {:error, {:bad_gateway, request_url}}

        _ ->
          raise """
            Failed to decode JSONRPC response:

            request:

              url:

              body:

            response:

              status code:

              body:
          """
      end
    end
  end

  defp handle_response(resp, 200) do
    case resp do
      %{error: error} -> {:error, standardize_error(error)}
      %{result: result} -> {:ok, result}
    end
  end

  defp handle_response(resp, _status) do
    {:error, resp}
  end

  # restrict response to only those fields supported by the JSON-RPC 2.0 standard, which means that level of keys is
  # validated, so we can indicate that with switch to atom keys.
  def standardize_response(%{jsonrpc: "2.0" = jsonrpc, id: id} = unstandardized) do
    # Nethermind return string ids
    id = to_integer(id)

    standardized = %{jsonrpc: jsonrpc, id: id}

    case unstandardized do
      %{result: _, error: _} ->
        raise ArgumentError,
              "result and error keys are mutually exclusive in JSONRPC 2.0 response objects, but got #{inspect(unstandardized)}"

      %{result: result} ->
        Map.put(standardized, :result, result)

      %{error: error} ->
        Map.put(standardized, :error, standardize_error(error))
    end
  end

  # restrict error to only those fields supported by the JSON-RPC 2.0 standard, which means that level of keys is
  # validated, so we can indicate that with switch to atom keys.
  def standardize_error(%{code: code, message: message} = unstandardized)
      when is_integer(code) and is_binary(message) do
    standardized = %{code: code, message: message}

    case Map.fetch(unstandardized, "data") do
      {:ok, data} -> Map.put(standardized, :data, data)
      :error -> standardized
    end
  end
end
