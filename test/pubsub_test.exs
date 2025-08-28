defmodule Poolder.PubSubTest do
  use ExUnit.Case

  @moduletag :pubsub

  defmodule Receiver do
    def start_link(num) do
      spawn_link(fn -> loop(num) end)
    end

    defp loop(num) do
      receive do
        {:pubsub, topic, payload} ->
          IO.inspect({num, topic, payload}, label: "Received message")
          loop(num)

        :stop ->
          IO.puts("Receiver #{num} stopped")

        _ ->
          loop(num)
      end
    end
  end

  setup do
    server = :test_pubsub
    {:ok, _pid} = Poolder.PubSub.start_link(server)
    %{server: server}
  end

  test "subscribe, unsubscribe, kill process, list subscribers, broadcast with regex", %{
    server: server
  } do
    # Start 5 receiver processes
    receivers = for n <- 1..5, do: Receiver.start_link(n)
    topic = "news"
    topic2 = "sports"

    # Subscribe all to topic
    Enum.each(receivers, fn pid ->
      Poolder.PubSub.subscribe(server, topic, pid)
    end)

    # Subscribe 1,2,3 to topic2
    Enum.each(Enum.take(receivers, 3), fn pid ->
      Poolder.PubSub.subscribe(server, topic2, pid)
    end)

    # Unsubscribe process 5 from topic
    Poolder.PubSub.unsubscribe(server, topic, Enum.at(receivers, 0))

    # Kill process 5
    # Process.exit(Enum.at(receivers, 4), :kill)
    kpid = Enum.at(receivers, 4)
    send(kpid, :stop)
    # Wait for monitor cleanup
    :timer.sleep(100)

    # List subscribers for topic
    subs = Poolder.PubSub.subscribers(server, topic)
    IO.inspect(subs, label: "Subscribers")

    # List subscribers for topic2
    list_topics = Poolder.PubSub.list_topics(server, Enum.at(receivers, 0))
    list_topics_all = Poolder.PubSub.list_topics_all(server)
    IO.inspect(list_topics, label: "Topics")
    IO.inspect(list_topics_all, label: "Topics all")

    assert length(subs) == 3

    # Broadcast to topic
    Poolder.PubSub.broadcast(server, topic, "news topic")
    # Broadcast to topic2
    Poolder.PubSub.broadcast(server, topic2, "sports topic")
    # Broadcast with regex (should match both topics)
    Poolder.PubSub.broadcast(server, ~r/news|sports/, "regex message")

    # Stop all receivers
    Enum.each(receivers, fn pid ->
      if Process.alive?(pid), do: send(pid, :stop)
    end)

    :timer.sleep(100)
  end
end
