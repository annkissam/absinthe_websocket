defmodule AbsintheWebSocket.Supervisor do
  use Supervisor

  def start_link(args) do
    base_name = Keyword.get(args, :base_name)
    supervisor_name = Module.concat(base_name, Supervisor)

    Supervisor.start_link(__MODULE__, args, name: supervisor_name)
  end

  # name: OrgmanicQLApi.Websocket.Supervisor
  # name: OrgmanicQLApi.Websocket.QueryServer
  # name: OrgmanicQLApi.Websocket.SubscriptionServer

  def init(args) do
    base_name = Keyword.get(args, :base_name)
    query_server_name = Module.concat(base_name, QueryServer)
    subscription_server_name = Module.concat(base_name, SubscriptionServer)
    socket_name = Module.concat(base_name, Socket)

    url = Keyword.get(args, :url)
    token = Keyword.get(args, :token)
    subscriber = Keyword.get(args, :subscriber)
    resubscribe_on_disconnect = Keyword.get(args, :resubscribe_on_disconnect, false)
    disconnect_sleep = Keyword.get(args, :disconnect_sleep)

    children = [
      worker(AbsintheWebSocket.QueryServer, [[socket: socket_name],[name: query_server_name]]),
      worker(AbsintheWebSocket.SubscriptionServer, [[socket: socket_name, subscriber: subscriber], [name: subscription_server_name]]),
      worker(AbsintheWebSocket.WebSocket, [
        [
          subscription_server: subscription_server_name,
          url: url,
          token: token,
          resubscribe_on_disconnect: resubscribe_on_disconnect,
          disconnect_sleep: disconnect_sleep
        ],
        [name: socket_name]
      ]),
    ]

    # restart everything on failures
    # It'd be nice if the QueryServer & SubscriptionServer could recover...
    Supervisor.init(children, strategy: :one_for_all)
  end
end

