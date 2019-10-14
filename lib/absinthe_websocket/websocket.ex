defmodule AbsintheWebSocket.WebSocket do
  use WebSockex
  require Logger

  @heartbeat_sleep 30_000
  @disconnect_sleep 30_000

  def start_link(args, opts) do
    name = Keyword.get(opts, :name)
    async = Keyword.get(opts, :async)
    url = Keyword.get(args, :url)
    token = Keyword.get(args, :token)
    full_url = if token do
      query = URI.encode_query(%{"token" => token})
      "#{url}?#{query}"
    else
      url
    end
    subscription_server = Keyword.get(args, :subscription_server)
    resubscribe_on_disconnect = Keyword.get(args, :resubscribe_on_disconnect, false)
    disconnect_callback = Keyword.get(args, :disconnect_callback, nil)
    disconnect_sleep = Keyword.get(args, :disconnect_sleep, @disconnect_sleep)
    state = %{
      subscriptions: %{},
      subscriptions_info: %{},
      queries: %{},
      msg_ref: 0,
      heartbeat_timer: nil,
      socket: name,
      subscription_server: subscription_server,
      resubscribe_on_disconnect: resubscribe_on_disconnect,
      disconnect_callback: disconnect_callback,
      disconnect_sleep: disconnect_sleep,
      ready: false
    }
    WebSockex.start_link(full_url, __MODULE__, state, handle_initial_conn_failure: true, async: async, name: name)
  end

  def query(socket, pid, ref, query, variables \\ []) do
    WebSockex.cast(socket, {:query, {pid, ref, query, variables}})
  end

  def subscribe(socket, pid, subscription_name, query, variables \\ []) do
    WebSockex.cast(socket, {:subscribe, {pid, subscription_name, query, variables}})
  end

  def unsubscribe(socket, pid, subscription_name) do
    WebSockex.cast(socket, {:unsubscribe, {pid, subscription_name}})
  end

  def set_opt(socket, opt, value) do
    WebSockex.cast(socket, {:set_opt, opt, value})
  end

  def close(socket) do
    WebSockex.cast(socket, :close)
  end

  def handle_connect(_conn, %{socket: socket} = state) do
    # Logger.info "#{__MODULE__} - Connected: #{inspect conn}"

    WebSockex.cast(socket, {:join})

    # resubscribe on reconnect (i.e. subscriptions already exist in state)
    if Map.get(state, :resubscribe_on_disconnect), do: handle_resubscribe(socket, state)

    # Send a heartbeat
    heartbeat_timer = Process.send_after(self(), :heartbeat, @heartbeat_sleep)
    state = Map.put(state, :heartbeat_timer, heartbeat_timer)

    {:ok, state}
  end

  def handle_disconnect(map, %{heartbeat_timer: heartbeat_timer} = state) do
    Logger.error "#{__MODULE__} - Disconnected: #{inspect map}"

    GenServer.cast(state.subscription_server, {:disconnected})

    if heartbeat_timer do
      :timer.cancel(heartbeat_timer)
    end

    state = Map.put(state, :heartbeat_timer, nil)

    if state.disconnect_callback do
      state.disconnect_callback.()
    end

    :timer.sleep(state.disconnect_sleep)

    {:reconnect, %{state | ready: false}}
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
      payload: %{},
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

    subscriptions_info =
      state
      |> Map.get(:subscriptions_info, %{})
      |> Map.put(subscription_name, {pid, query, variables})

    state = state
    |> Map.put(:queries, queries)
    |> Map.put(:msg_ref, msg_ref + 1)
    |> Map.put(:subscriptions_info, subscriptions_info)

    {:reply, {:text, msg}, state}
  end

  def handle_cast({:unsubscribe, {pid, subscription_name}}, %{queries: queries, msg_ref: msg_ref} = state) do
    subscription = Enum.find(state.subscriptions, fn
      {_, {^pid, ^subscription_name}} -> true
      _ -> false
    end)

    with {subscription_id, _} <- subscription do
      msg = %{
        topic: "__absinthe__:control",
        event: "unsubscribe",
        payload: %{"subscriptionId" => subscription_id},
        ref: msg_ref
      } |> Poison.encode!

      queries = Map.put(queries, msg_ref, {:unsubscribe, pid, subscription_name})

      subscriptions_info =
        state
        |> Map.get(:subscriptions_info, %{})
        |> Map.delete(subscription_name)

      state = state
      |> Map.put(:queries, queries)
      |> Map.put(:msg_ref, msg_ref + 1)
      |> Map.put(:subscriptions_info, subscriptions_info)

      {:reply, {:text, msg}, state}
    else
      _ -> {:ok, state}
    end
  end

  def handle_cast({:set_opt, opt, value}, state) do
    {:ok, %{state | opt => value}}
  end

  def handle_cast(:close, state) do
    {:close, state}
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

    status = payload["status"] |> String.to_atom()

    state = case command do
      {:query, pid, ref} ->
        errors = payload["response"]["errors"]
        case status do
          :ok ->
            data = payload["response"]["data"]
            GenServer.cast(pid, {:query_response, ref, {status, data, errors}})
          :error ->
            GenServer.cast(pid, {:query_response, ref, {status, errors}})
        end
        state
      {:subscribe, pid, subscription_name} ->
        unless status == :ok do
          raise "Subscription Error - #{inspect payload}"
        end

        subscription_id = payload["response"]["subscriptionId"]
        subscriptions = Map.put(state.subscriptions, subscription_id, {pid, subscription_name})
        Map.put(state, :subscriptions, subscriptions)
      {:unsubscribe, _pid, _subscription_name} ->
        unless status == :ok do
          raise "Unsubscribe Error - #{inspect payload}"
        end

        subscription_id = payload["response"]["subscriptionId"]
        subscriptions = Map.delete(state.subscriptions, subscription_id)
        Map.put(state, :subscriptions, subscriptions)
      {:join} ->
        unless status == :ok do
          raise "Join Error - #{inspect payload}"
        end

        GenServer.cast(state.subscription_server, {:joined})

        %{state | ready: true}
      {:heartbeat} ->
        unless status == :ok do
          raise "Heartbeat Error - #{inspect payload}"
        end

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

  def handle_resubscribe(socket, state) do
    state
    |> Map.get(:subscriptions_info, %{})
    |> Enum.each(fn {sub_name, {pid, query, variables}} ->
      subscribe(socket, pid, sub_name, query, variables)
    end)
  end
end
