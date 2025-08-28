defmodule Poolder.PubSub.PhoenixAdapter do
  @moduledoc """
  Phoenix.PubSub adapter for Poolder.PubSub.
  Allows Poolder.PubSub to be used as a Phoenix PubSub backend.

  ## Usage

  Add to your Phoenix application's config:

      config :my_app, MyApp.Endpoint,
        pubsub_server: MyApp.PubSub

      config :my_app, MyApp.PubSub,
        adapter: Poolder.PubSub.PhoenixAdapter,
        name: MyApp.PubSub

  Or in your supervision tree:

      children = [
        {Phoenix.PubSub, adapter: Poolder.PubSub.PhoenixAdapter, name: MyApp.PubSub}
      ]

  You can now use Phoenix.PubSub functions as usual:

      Phoenix.PubSub.subscribe(MyApp.PubSub, "room:lobby")
      Phoenix.PubSub.broadcast(MyApp.PubSub, "room:lobby", {:msg, "hello"})

  """

  def child_spec(opts) do
    server = Keyword.fetch!(opts, :name)

    %{
      id: server,
      start: {Poolder.PubSub, :start_link, [server, opts]}
    }
  end

  def subscribe(server, topic, opts) do
    pid = Keyword.get(opts, :pid, self())
    Poolder.PubSub.subscribe(server, topic, pid)
  end

  def unsubscribe(server, topic, opts) do
    pid = Keyword.get(opts, :pid, self())
    Poolder.PubSub.unsubscribe(server, topic, pid)
  end

  def broadcast(server, topic, message) do
    Poolder.PubSub.broadcast(server, topic, message)
  end

  def broadcast_from(server, from, topic, message) do
    # Poolder.PubSub does not track sender, so just broadcast
    Poolder.PubSub.broadcast_from(server, from, topic, message)
  end

  def link(_server), do: :ok

  def node_name(_server), do: node()

  def direct_broadcast(server, _node, topic, message) do
    Poolder.PubSub.broadcast(server, topic, message)
  end
end
