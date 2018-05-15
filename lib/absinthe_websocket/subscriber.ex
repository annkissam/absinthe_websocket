defmodule AbsintheWebSocket.Subscriber do
  @callback subscribe() :: no_return()

  # @callback receive(atom(), any) :: no_return()
end
