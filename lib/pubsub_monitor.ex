defmodule Poolder.PubSub.Monitor do
  @moduledoc """
  Lightweight monitor process (not a GenServer) that:
    - Creates monitors for subscribed pids
    - Demonitor pids that no longer have subscriptions
    - Cleans up subscriptions upon receiving :DOWN
  """

  @doc "Starts the monitor process linked to the given ETS."
  def start_link(table) do
    pid = spawn_link(__MODULE__, :loop, [table])
    {:ok, pid}
  end

  @doc false
  def loop(table) do
    receive do
      {:ensure_monitor, ^table, pid} when is_pid(pid) ->
        ensure_monitor_entry(table, pid)
        loop(table)

      {:maybe_demonitor, ^table, pid} when is_pid(pid) ->
        maybe_demonitor_entry(table, pid)
        loop(table)

      {:DOWN, ref, :process, pid, _reason} ->
        # Verify that the :DOWN corresponds to a monitor that we manage
        case :ets.lookup(table, {:mon, pid}) do
          [{{:mon, ^pid}, ^ref}] ->
            cleanup_pid(table, pid)
            loop(table)

          _ ->
            loop(table)
        end
    after
      300_000 ->
        :erlang.hibernate(__MODULE__, :loop, [table])
    end
  end

  # --- internal helpers ---

  defp ensure_monitor_entry(table, pid) do
    case :ets.lookup(table, {:mon, pid}) do
      [] ->
        ref = Process.monitor(pid)
        :ets.insert(table, {{:mon, pid}, ref})

      _ ->
        :ok
    end
  end

  defp maybe_demonitor_entry(table, pid) do
    case has_any_subscription?(table, pid) do
      true ->
        :ok

      false ->
        case :ets.lookup(table, {:mon, pid}) do
          [{{:mon, ^pid}, ref}] ->
            Process.demonitor(ref, [:flush])
            :ets.delete(table, {:mon, pid})

          _ ->
            :ok
        end
    end
  end

  defp has_any_subscription?(table, pid) do
    case :ets.select(table, [
           {{{:sub, :_, pid}, :_}, [], [true]}
         ]) do
      [] -> false
      _ -> true
    end
  end

  defp cleanup_pid(table, pid) do
    # Removes all subscriptions {topic, pid}
    subs =
      :ets.select(table, [
        {{{:sub, :"$1", pid}, :_}, [], [:"$1"]}
      ])

    Enum.each(subs, fn topic ->
      :ets.delete(table, {:sub, topic, pid})
    end)

    :ets.delete(table, {:mon, pid})
  end
end
