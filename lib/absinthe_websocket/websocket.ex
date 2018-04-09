defmodule AbsintheWebSocket.WebSocket do
  use WebSockex
  require Logger

  @heartbeat_sleep 30_000
  @disconnect_sleep 30_000

  def start_link(args, opts) do
    name = Keyword.get(opts, :name)
    url = Keyword.get(args, :url)
    token = Keyword.get(args, :token)
    subscription_server = Keyword.get(args, :subscription_server)
    full_url = "#{url}?token=#{token}"
    state = %{subscriptions: %{}, queries: %{}, msg_ref: 0, heartbeat_timer: nil, socket: name, subscription_server: subscription_server}
    WebSockex.start_link(full_url, __MODULE__, state, handle_initial_conn_failure: true, async: true, name: name)
  end

  def query(socket, pid, ref, query, variables \\ []) do
    WebSockex.cast(socket, {:query, {pid, ref, query, variables}})
  end

  def subscribe(socket, pid, subscription_name, query, variables \\ []) do
    WebSockex.cast(socket, {:subscribe, {pid, subscription_name, query, variables}})
  end

  def handle_connect(_conn, %{socket: socket} = state) do
    # Logger.info "#{__MODULE__} - Connected: #{inspect conn}"

    WebSockex.cast(socket, {:join})

    # Send a heartbeat
    heartbeat_timer = Process.send_after(self(), :heartbeat, @heartbeat_sleep)
    state = Map.put(state, :heartbeat_timer, heartbeat_timer)

    {:ok, state}
  end

  def handle_disconnect(map, %{heartbeat_timer: heartbeat_timer} = state) do
    Logger.error "#{__MODULE__} - Disconnected: #{inspect map}"

    if heartbeat_timer do
      :timer.cancel(heartbeat_timer)
    end

    state = Map.put(state, :heartbeat_timer, nil)

    :timer.sleep(@disconnect_sleep)

    {:reconnect, state}
  end

  def handle_info(:heartbeat, %{socket: socket} = state) do
    WebSockex.cast(socket, {:heartbeat})

    # Send another heartbeat
    heartbeat_timer = Process.send_after(self(), :heartbeat, @heartbeat_sleep)
    state = Map.put(state, :heartbeat_timer, heartbeat_timer)

    {:ok, state}
  end

  def handle_info(msg, state) do
    Logger.info "#{__MODULE__} Info - Message: #{inspect msg}"

    {:ok, state}
  end

  def handle_cast({:join}, %{queries: queries, msg_ref: msg_ref} = state) do
    msg = %{
      topic: "__absinthe__:control",
      event: "phx_join",
      payload: %{token: "TEST"},
      ref: msg_ref
    } |> Poison.encode!

    queries = Map.put(queries, msg_ref, {:join})

    state = state
    |> Map.put(:queries, queries)
    |> Map.put(:msg_ref, msg_ref + 1)

    {:reply, {:text, msg}, state}
  end

  # Heartbeat: http://graemehill.ca/websocket-clients-and-phoenix-channels/
  # https://stackoverflow.com/questions/34948331/how-to-implement-a-resetable-countdown-timer-with-a-genserver-in-elixir-or-erlan
  def handle_cast({:heartbeat}, %{queries: queries, msg_ref: msg_ref} = state) do
    msg = %{
      topic: "phoenix",
      event: "heartbeat",
      payload: %{},
      ref: msg_ref
    } |> Poison.encode!

    queries = Map.put(queries, msg_ref, {:heartbeat})

    state = state
    |> Map.put(:queries, queries)
    |> Map.put(:msg_ref, msg_ref + 1)

    {:reply, {:text, msg}, state}
  end

  def handle_cast({:query, {pid, ref, query, variables}}, %{queries: queries, msg_ref: msg_ref} = state) do
    doc = %{
      "query" => query,
      "variables" => variables,
    }

    msg = %{
      topic: "__absinthe__:control",
      event: "doc",
      payload: doc,
      ref: msg_ref
    } |> Poison.encode!

    queries = Map.put(queries, msg_ref, {:query, pid, ref})

    state = state
    |> Map.put(:queries, queries)
    |> Map.put(:msg_ref, msg_ref + 1)

    {:reply, {:text, msg}, state}
  end

  def handle_cast({:subscribe, {pid, subscription_name, query, variables}}, %{queries: queries, msg_ref: msg_ref} = state) do
    doc = %{
      "query" => query,
      "variables" => variables,
    }

    msg = %{
      topic: "__absinthe__:control",
      event: "doc",
      payload: doc,
      ref: msg_ref
    } |> Poison.encode!

    queries = Map.put(queries, msg_ref, {:subscribe, pid, subscription_name})

    state = state
    |> Map.put(:queries, queries)
    |> Map.put(:msg_ref, msg_ref + 1)

    {:reply, {:text, msg}, state}
  end

  def handle_cast(message, state) do
    Logger.info "#{__MODULE__} - Cast: #{inspect message}"

    super(message, state)
  end

  def handle_frame({:text, msg}, state) do
    msg = msg
    |> Poison.decode!()

    handle_msg(msg, state)
  end

  def handle_msg(%{"event" => "phx_reply", "payload" => payload, "ref" => msg_ref}, state) do
    # Logger.info "#{__MODULE__} - Reply: #{inspect msg}"

    queries = state.queries
    {command, queries} = Map.pop(queries, msg_ref)
    state = Map.put(state, :queries, queries)

    state = case command do
      {:query, pid, ref} ->
        data = payload["response"]["data"]
        GenServer.cast(pid, {:query_response, ref, data})
        state
      {:subscribe, pid, subscription_name} ->
        subscription_id = payload["response"]["subscriptionId"]
        subscriptions = Map.put(state.subscriptions, subscription_id, {pid, subscription_name})
        Map.put(state, :subscriptions, subscriptions)
      {:join} ->
        GenServer.cast(state.subscription_server, {:joined})
        state
      {:heartbeat} ->
        state
    end

    {:ok, state}
  end

  def handle_msg(%{"event" => "subscription:data", "payload" => payload, "topic" => subscription_id}, %{subscriptions: subscriptions} = state) do
    # Logger.info "#{__MODULE__} - Subscription: #{inspect msg}"
    {pid, subscription_name} = Map.get(subscriptions, subscription_id)

    data = payload["result"]["data"]

    GenServer.cast(pid, {:subscription, subscription_name, data})

    {:ok, state}
  end

  def handle_msg(msg, state) do
    Logger.info "#{__MODULE__} - Msg: #{inspect msg}"

    {:ok, state}
  end
end
