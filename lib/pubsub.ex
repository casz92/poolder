defmodule Poolder.PubSub do
  @moduledoc """
  ETS-based public PubSub, identified by a logical `server`.

  - `server` is the name you pass to start_link/1
  - Internally, the ETS table is registered in :persistent_term with key {:pubsub, server}
  - All functions receive the server as the first argument and resolve the ETS from there
  """

  @type server :: atom()
  @type table :: atom()

  # ==========================
  # Startup
  # ==========================
  @doc """
  Starts a PubSub server named `server` and creates the public ETS.

  Options:
    - :table => ETS name (by default uses :"\#{server}_pubsub")
  """
  def start_link(server, _opts \\ []) when is_atom(server) do
    tid = ensure_table!(server)
    :persistent_term.put({:pubsub, server}, tid)

    {:ok, mon_pid} = Poolder.PubSub.Monitor.start_link(tid)
    :ets.insert(tid, {{:sys, :monitor_pid}, mon_pid})
    {:ok, mon_pid}
  end

  defp ensure_table!(table) do
    case :ets.whereis(table) do
      :undefined ->
        :ets.new(table, [
          :public,
          :set,
          {:read_concurrency, true},
          {:write_concurrency, true}
        ])

      tid ->
        tid
    end
  end

  defp table_for(server) when is_reference(server), do: server

  defp table_for(server) do
    case :persistent_term.get({:pubsub, server}, nil) do
      nil -> raise ArgumentError, "PubSub server #{inspect(server)} not initialized"
      table -> table
    end
  end

  defp monitor_pid!(table) do
    case :ets.lookup(table, {:sys, :monitor_pid}) do
      [{{:sys, :monitor_pid}, pid}] -> pid
      _ -> raise "Monitor not initialized"
    end
  end

  # ==========================
  # Subscription
  # ==========================
  def subscribe(server, topic, pid \\ self()) do
    table = table_for(server)
    # topic = normalize_topic!(topic)
    :ets.insert(table, {{:sub, topic, pid}, true})
    ensure_monitor(table, pid)
  end

  def unsubscribe(server, topic, pid \\ self()) do
    table = table_for(server)
    # topic = normalize_topic!(topic)
    :ets.delete(table, {:sub, topic, pid})
    maybe_demonitor(table, pid)
  end

  # ==========================
  # Listings
  # ==========================
  def subscribers(server, topic) do
    table = table_for(server)
    # topic = normalize_topic!(topic)

    :ets.select(table, [
      {{{:sub, topic, :"$1"}, :_}, [], [:"$1"]}
    ])
  end

  def list_topics(server, pid) do
    table = table_for(server)

    :ets.select(table, [
      {{{:sub, :"$1", pid}, :_}, [], [:"$1"]}
    ])
  end

  def list_all(server) do
    table = table_for(server)

    :ets.select(table, [
      {{{:sub, :"$1", :"$2"}, :_}, [], [{{:"$1", :"$2"}}]}
    ])
  end

  def list_topics_all(server) do
    table = table_for(server)

    table
    |> :ets.select([{{{:sub, :"$1", :_}, :_}, [], [:"$1"]}])
    |> Enum.uniq()
  end

  # ==========================
  # Broadcast
  # ==========================
  def broadcast(server, %Regex{} = regex, payload) do
    table = table_for(server)
    topics = list_topics_all(table) |> Enum.filter(&Regex.match?(regex, &1))
    Enum.each(topics, &broadcast(table, &1, payload))
  end

  def broadcast(server, topic, payload) do
    table = table_for(server)
    # topic = normalize_topic!(topic)

    subscribers(table, topic)
    |> Enum.each(fn pid -> send(pid, {:pubsub, topic, payload}) end)
  end

  def broadcast_from(server, pid, topic, payload) do
    table = table_for(server)

    subscribers(table, topic)
    |> Enum.filter(&(&1 != pid))
    |> Enum.each(fn pid -> send(pid, {:pubsub, topic, payload}) end)
  end

  # ==========================
  # Internal monitor
  # ==========================
  defp ensure_monitor(table, pid) do
    case :ets.lookup(table, {:mon, pid}) do
      [] ->
        mon = monitor_pid!(table)
        send(mon, {:ensure_monitor, table, pid})
        :ok

      _ ->
        :ok
    end
  end

  defp maybe_demonitor(table, pid) do
    case :ets.select(table, [
           {{{:sub, :_, pid}, :_}, [], [true]}
         ]) do
      [] ->
        case :ets.lookup(table, {:mon, pid}) do
          [{{:mon, ^pid}, _ref}] ->
            mon = monitor_pid!(table)
            send(mon, {:maybe_demonitor, table, pid})
            :ok

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  def stop(server) do
    table = table_for(server)
    mon = monitor_pid!(table)
    send(mon, :stop)
  end

  # defp normalize_topic!(topic) when is_binary(topic), do: topic
  # defp normalize_topic!(topic) when is_atom(topic), do: Atom.to_string(topic)

  # defp normalize_topic!(other),
  #   do: raise(ArgumentError, "topic must be binary or atom, got: #{inspect(other)}")
end
