defmodule AbsintheWebSocket.QueryServer do
  use GenServer

  def start_link(args, opts) do
    socket = Keyword.get(args, :socket)
    state = %{
      socket: socket,
      queries: %{},
    }
    GenServer.start_link(__MODULE__, state, opts)
  end

  def init(state) do
    {:ok, state}
  end

  def post(mod, query, variables \\ [], opts \\ []) do
    GenServer.call(mod, {:post, query, variables}, opts[:timeout] || 5_000)
  end

  def handle_call({:post, query, variables}, from, %{socket: socket, queries: queries} = state) do
    ref = make_ref()

    AbsintheWebSocket.WebSocket.query(socket, self(), ref, query, variables)

    queries = Map.put(queries, ref, from)
    state = Map.put(state, :queries, queries)

    {:noreply, state}
  end

  def handle_cast({:query_response, ref, response}, %{queries: queries} = state) do
    {from, queries} = Map.pop(queries, ref)

    GenServer.reply(from, response)

    state = Map.put(state, :queries, queries)

    {:noreply, state}
  end
end
