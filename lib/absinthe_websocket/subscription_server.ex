defmodule AbsintheWebSocket.SubscriptionServer do
  use GenServer
  require Logger

  def start_link(args, opts) do
    socket = Keyword.get(args, :socket)
    subscriber = Keyword.get(args, :subscriber)
    state = %{
      connected?: false,
      disconnected_casts: [],
      socket: socket,
      subscriber: subscriber,
      subscriptions: %{},
    }
    GenServer.start_link(__MODULE__, state, opts)
  end

  def init(state) do
    {:ok, state}
  end

  def subscribe(mod, subscription_name, callback, query, variables \\ []) do
    GenServer.cast(mod, {:subscribe, subscription_name, callback, query, variables})
  end

  def unsubscribe(mod, subscription_name) do
    GenServer.cast(mod, {:unsubscribe, subscription_name})
  end

  def handle_cast({:subscribe, _, _, _, _} = message, %{connected?: false} = state) do
    state = Map.put(state, :disconnected_casts, state.disconnected_casts ++ [message])

    {:noreply, state}
  end

  def handle_cast({:subscribe, subscription_name, callback, query, variables}, %{socket: socket, subscriptions: subscriptions} = state) do
    AbsintheWebSocket.WebSocket.subscribe(socket, self(), subscription_name, query, variables)

    callbacks = Map.get(subscriptions, subscription_name, [])
    subscriptions = Map.put(subscriptions, subscription_name, [callback | callbacks])
    state = Map.put(state, :subscriptions, subscriptions)

    {:noreply, state}
  end

  def handle_cast({:unsubscribe, _} = message, %{connected?: false} = state) do
    state = Map.put(state, :disconnected_casts, state.disconnected_casts ++ [message])

    {:noreply, state}
  end

  def handle_cast({:unsubscribe, subscription_name}, %{socket: socket, subscriptions: subscriptions} = state) do
    AbsintheWebSocket.WebSocket.unsubscribe(socket, self(), subscription_name)

    subscriptions = Map.delete(subscriptions, subscription_name)
    state = Map.put(state, :subscriptions, subscriptions)

    {:noreply, state}
  end

  # Incoming Notifications (from AbsintheWebSocket.WebSocket)
  def handle_cast({:subscription, subscription_name, response}, %{subscriptions: subscriptions} = state) do
    # handle_subscription(subscription_name, response)

    Map.get(subscriptions, subscription_name, [])
    |> Enum.each(fn(callback) -> callback.(response) end)

    {:noreply, state}
  end

  def handle_cast({:joined}, %{subscriber: subscriber} = state) do
    apply(subscriber, :subscribe, [])

    Enum.each(state.disconnected_casts, &GenServer.cast(self(), &1))
    state = Map.merge(state, %{connected?: true, disconnected_casts: []})

    {:noreply, state}
  end

  def handle_cast({:disconnected}, state) do
    {:noreply, Map.put(state, :connected?, false)}
  end
end
