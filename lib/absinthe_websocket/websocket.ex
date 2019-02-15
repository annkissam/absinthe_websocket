defmodule AbsintheWebSocket.WebSocket do
  use WebSockex
  require Logger

  @heartbeat_sleep 30_000
  @disconnect_sleep 30_000

  def start_link(args, opts) do
    name = Keyword.get(opts, :name)
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
      disconnect_sleep: disconnect_sleep
    }
    WebSockex.start_link(full_url, __MODULE__, state, handle_initial_conn_failure: true, async: true, name: name)
  end

  def query(socket, pid, ref, query, variables \\ []) do
    WebSockex.cast(socket, {:query, {pid, ref, query, variables}})
  end

  def subscribe(socket, pid, subscription_name, query, variables \\ [], opts \\ []) do
    WebSockex.cast(socket, {:subscribe, {pid, subscription_name, query, variables, opts}})
  end

  def unsubscribe(socket, pid, subscription_name) do
    WebSockex.cast(socket, {:unsubscribe, {pid, subscription_name}})
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

    if heartbeat_timer do
      :timer.cancel(heartbeat_timer)
    end

    state = Map.put(state, :heartbeat_timer, nil)

    :timer.sleep(state.disconnect_sleep)

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

  def handle_cast({:subscribe, {pid, subscription_name, query, variables, opts}}, %{queries: queries, msg_ref: msg_ref} = state) do
    subscriptions = get_in(state, [:subscriptions_info, subscription_name])

    if is_nil(subscriptions) || opts[:resubscribe] do
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

      state =
        state
        |> Map.put(:queries, queries)
        |> Map.put(:msg_ref, msg_ref + 1)
        |> Map.put(:subscriptions_info, subscriptions_info)

      {:reply, {:text, msg}, state}

    else
      {:ok, state}
    end
  end

  def handle_cast({:unsubscribe, {pid, subscription_name}}, %{queries: queries, msg_ref: msg_ref} = state) do
    subscription =
      Enum.find(state.subscriptions, fn {_, subscriptions} ->
        List.keymember?(subscriptions, subscription_name, 0)
      end)

    subscriptions_info =
      state
      |> Map.get(:subscriptions_info, %{})
      |> Map.delete(subscription_name)


    case subscription do
      {subscription_id, subscriptions} ->
        case List.keydelete(subscriptions, subscription_name, 0) do
          [] ->
            msg =
              %{
                topic: "__absinthe__:control",
                event: "unsubscribe",
                payload: %{"subscriptionId" => subscription_id},
                ref: msg_ref
              }
              |> Poison.encode!()

            queries = Map.put(queries, msg_ref, {:unsubscribe, pid, subscription_name})

            state =
              state
              |> Map.put(:queries, queries)
              |> Map.put(:msg_ref, msg_ref + 1)
              |> Map.put(:subscriptions_info, subscriptions_info)

            {:reply, {:text, msg}, state}

          subscriptions ->
            state =
              state
              |> Map.update!(:subscriptions, &Map.put(&1, subscription_id, subscriptions))
              |> Map.put(:subscriptions_info, subscriptions_info)

            {:ok, state}
        end

      _ -> {:ok, state}
    end
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
        case status do
          :ok ->
            data = payload["response"]["data"]
            GenServer.cast(pid, {:query_response, ref, {status, data}})
          :error ->
            errors = payload["response"]["errors"]
            GenServer.cast(pid, {:query_response, ref, {status, errors}})
        end
        state
      {:subscribe, pid, subscription_name} ->
        unless status == :ok do
          raise "Subscription Error - #{inspect payload}"
        end

        subscription_id = payload["response"]["subscriptionId"]

        subscriptions =
          Map.update(
            state.subscriptions,
            subscription_id,
            [{subscription_name, pid}],
            &[{subscription_name, pid} | &1]
          )

        state = Map.put(state, :subscriptions, subscriptions)
        state
      {:unsubscribe, _pid, subscription_name} ->
        unless status == :ok do
          raise "Unsubscribe Error - #{inspect payload}"
        end

        subscription_id = payload["response"]["subscriptionId"]

        subscriptions =
          state.subscriptions
          |> Map.get(subscription_id, [])
          |> List.keydelete(subscription_name, 0)
          |> case do
            [] -> Map.delete(state.subscriptions, subscription_id)
            subscription -> Map.put(state.subscriptions, subscription_id, subscription)
          end

        Map.put(state, :subscriptions, subscriptions)
      {:join} ->
        unless status == :ok do
          raise "Join Error - #{inspect payload}"
        end

        GenServer.cast(state.subscription_server, {:joined})

        state
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

    data = payload["result"]["data"]

    subscriptions
    |> Map.get(subscription_id)
    |> Enum.each(fn {subscription_name, pid} ->
      GenServer.cast(pid, {:subscription, subscription_name, data})
    end)

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
      subscribe(socket, pid, sub_name, query, variables, resubscribe: true)
    end)
  end
end
