defmodule Binance.WebSocket.WSClient do
  @moduledoc """
  WebSocket client for Binance Spot

  There are 2 types of WebSocket channels/streams for Spot trading on Binance:

  - [Public streams](https://github.com/binance-exchange/binance-official-api-docs/blob/master/web-socket-streams.md)
  - [User Data stream](https://github.com/binance-exchange/binance-official-api-docs/blob/master/user-data-stream.md)

  Use the `require_auth` option to indicate if we're going to subscribe to User Data stream or not.
  If we're not, use `public_channels` to list out channels/streams we would like to subscribe to.
  Or said it in other way, `public_channels` will be ignored when `require_auth` is `true`.

  Note: User Data stream requires to have a listen key created beforehand. A listen key needs
  to be keepalive every 30 mins otherwise the stream would be closed after 30mins. This WebSocket client
  by default sets the interval time for keepalive the stream to be 10mins (see @keep_alive_interval)

  Also, this WebSocket client maintains a heartbeat mechanism by sending a ping every 5_000ms (see @ping interval)
  to check if the WebSocket server is in connected and to decide whether to continue to keep the connection or
  terminate the current one and start a new one.

  Usage example:

  defmodule A do
    use Binance.WebSocket.WSClient
  end

  # Public channels/streams
  A.start_link(%{name: :"btcusdt-depth-stream", public_channels: ["btcusdt@depth"]})

  # User Data stream
  config = %{access_keys: ["XXX_BINANCE_API_KEY", "XXX_BINANCE_SECRET_KEY"]}
  A.start_link(%{name: :"user-data-stream", require_auth: true, config: config})
  """

  import Logger, only: [info: 1, warn: 1]
  import Process, only: [send_after: 3]

  # Client API
  defmacro __using__(_opts) do
    quote do
      use WebSockex
      @base Application.get_env(:binance, :ws_margin_endpoint, "wss://stream.binance.com:9443")
      @ping_interval Application.get_env(:binance, :ping_interval, 5_000)
      @keep_alive_interval Application.get_env(:binance, :keep_alive_interval, 10 * 60_000)

      def start_link(args \\ %{}) do
        name = args[:name] || __MODULE__
        require_auth = args[:require_auth] || false
        public_channels = args[:public_channels]
        config = args[:config]
        state = Map.merge(args, %{heartbeat: 0, listen_key: nil})

        if require_auth == true do
          {:ok, %{"listenKey" => listen_key}} = Binance.create_listen_key(config)
          state = Map.merge(state, %{listen_key: listen_key})
          endpoint_url = prepare_endpoint_url(listen_key)
          WebSockex.start_link(endpoint_url, __MODULE__, state, name: name)
        else
          endpoint_url = prepare_endpoint_url(public_channels)
          WebSockex.start_link(endpoint_url, __MODULE__, state, name: name)
        end
      end

      def schedule_keep_alive_stream() do
        send_after(self(), :keep_alive, @keep_alive_interval)
      end

      def prepare_endpoint_url(stream_name) when is_binary(stream_name) do
        @base <> "/ws/" <> stream_name
      end

      def prepare_endpoint_url(stream_names) when is_list(stream_names) do
        @base <> "/stream?streams=" <> Enum.join(stream_names, "/")
      end

      # Callbacks

      def handle_pong(:pong, state) do
        {:ok, inc_heartbeat(state)}
      end

      def handle_connect(_conn, state) do
        :ok = info("Binance Spot Connected!")
        send_after(self(), {:heartbeat, :ping}, 20_000)

        # If this is User Data stream, schedule a process to keepalive the stream every 10mins (see @keep_alive_interval)
        if state.listen_key do
          schedule_keep_alive_stream()
        end

        {:ok, state}
      end

      def handle_info(:keep_alive, %{listen_key: listen_key, config: config} = state) do
        {:ok, _} = Binance.keep_alive_listen_key(listen_key, config)
        :ok = info("Keepalive Binance's User Data stream done!")
        schedule_keep_alive_stream()
        {:ok, state}
      end

      def handle_info({:ws_reply, frame}, state) do
        {:reply, frame, state}
      end

      def handle_info({:heartbeat, :ping}, state) do
        send_after(self(), {:heartbeat, :ping}, 4_000)
        {:reply, :ping, state}
      end

      @doc """
      Handles pong response from the Binance
      """
      def handle_frame({:binary, <<43, 200, 207, 75, 7, 0>> = pong}, state) do
        pong
        |> :zlib.unzip()
        |> handle_response(state |> inc_heartbeat())
      end

      def handle_frame({:text, json_data}, state) do
        response = json_data |> Poison.decode!()
        handle_response(response, state)
      end

      def handle_response(resp, state) do
        :ok = info("#{__MODULE__} received response: #{inspect(resp)}")
        {:ok, state}
      end

      def handle_disconnect(resp, state) do
        :ok = info("Binance Spot Disconnected! #{inspect(resp)}")
        {:ok, state}
      end

      def terminate({:local, :normal}, %{catch_terminate: pid}),
        do: send(pid, :normal_close_terminate)

      def terminate(_, %{catch_terminate: pid}), do: send(pid, :terminate)
      def terminate(_, _), do: :ok

      # Helpers

      defp inc_heartbeat(%{heartbeat: heartbeat} = state) do
        Map.put(state, :heartbeat, heartbeat + 1)
      end

      defoverridable handle_connect: 2, handle_disconnect: 2, handle_response: 2, terminate: 2
    end
  end
end
