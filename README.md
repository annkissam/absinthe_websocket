# AbsintheWebSocketHR

This libary uses WebSockets to communicate with a GraphQL endpoint built using Absinthe and Phoenix Channels. Its primary goal is to allow clients to use [Subscriptions](https://hexdocs.pm/absinthe/subscriptions.html), although it also supports queries. It uses [WebSockex](https://github.com/Azolo/websockex) as a WebSocket client. It also handles the specifics of Phoenix Channels (heartbeats) and how Absinthe subscriptions were implemented on top of them.  

It is a fork of https://hexdocs.pm/absinthe_websocket, it contains following bug fix: [https://github.com/karlosmid/absinthe_websocket/commit/b08e0cf07c1dcdbb98e14c3905d8ee7b777aee66](https://github.com/karlosmid/absinthe_websocket/commit/b08e0cf07c1dcdbb98e14c3905d8ee7b777aee66)

## Documentation

Docs can be found at [https://hexdocs.pm/absinthe_websocket](https://hexdocs.pm/absinthe_websocket).

A complete walkthrough can be found on the [Annkissam Alembic](https://www.annkissam.com/elixir/alembic/posts/2018/07/13/graphql-subscriptions-connecting-phoenix-applications-with-absinthe-and-websockets.html). It also has an associated [demo](https://github.com/annkissam/absinthe_websocket_demo).

## Installation

The simplest way to get started is to use the [common_graphql_client](https://github.com/annkissam/common_graphql_client). The readme and associated tutorial walk through the complete installation.
