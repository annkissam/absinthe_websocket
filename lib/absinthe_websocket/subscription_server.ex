defmodule AbsintheWebSocket.SubscriptionServer do
  use GenServer
  require Logger

  def start_link(args, opts) do
    socket = Keyword.get(args, :socket)
    subscriber = Keyword.get(args, :subscriber)
    state = %{
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

  def handle_cast({:subscribe, subscription_name, callback, query, variables}, %{socket: socket, subscriptions: subscriptions} = state) do
    AbsintheWebSocket.WebSocket.subscribe(socket, self(), subscription_name, query, variables)

    callbacks = Map.get(subscriptions, subscription_name, [])
    subscriptions = Map.put(subscriptions, subscription_name, [callback | callbacks])
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

    {:noreply, state}
  end
end
