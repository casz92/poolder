defmodule Poolder.FactoryPool do
  @moduledoc """
  Dynamic pool of grouped processes with fast lookup by group or pid.

  ## Usage examples

    # Start a worker under group :http
    Poolder.FactoryPool.start_child(:http, {MyWorker, args})

    # Synchronous call to specific pid
    Poolder.FactoryPool.call(pid, :ping)

    # Async message to a specific pid
    Poolder.FactoryPool.cast(pid, :refresh)

    # Broadcast to all workers in a group
    Poolder.FactoryPool.broadcast(:http, :reload)

    # Count active workers in a group
    Poolder.FactoryPool.count(:http)
  """

  # :bag — {group, pid}
  @group_table __MODULE__.GroupTable
  # :set — {pid, group}
  @pid_table __MODULE__.PidTable

  def child_spec(opts) do
    %{
      id: opts[:id] || __MODULE__,
      start: {__MODULE__, :start_link, []},
      type: :worker,
      restart: :transient,
      shutdown: 500
    }
  end

  @doc "Initializes ETS tables for group and pid tracking"
  def start_link do
    :ets.new(@group_table, [:named_table, :bag, :public, read_concurrency: true])
    :ets.new(@pid_table, [:named_table, :set, :public, read_concurrency: true])

    case Poolder.FactoryPool.Monitor.start_link([]) do
      {:ok, _} -> :ignore
      {:error, {:already_started, _}} -> :ignore
      error -> error
    end
  end

  @doc "Starts a worker process under a group and tracks it in ETS"
  def start_child(group \\ :default, {mod, args}) do
    sup_name = via_supervisor(group)

    spec = %{
      id: make_ref(),
      start: {mod, :start_link, [args]},
      restart: :temporary
    }

    with {:ok, pid} <- DynamicSupervisor.start_child(sup_name, spec) do
      :ets.insert(@group_table, {group, pid})
      :ets.insert(@pid_table, {pid, group})
      Poolder.FactoryPool.Monitor.monitor(pid)
      {:ok, pid}
    end
  end

  @doc "Terminates a child process and removes its ETS references"
  def terminate(pid) when is_pid(pid) do
    case :ets.lookup(@pid_table, pid) do
      [{^pid, group}] ->
        :ets.delete_object(@group_table, {group, pid})
        :ets.delete(@pid_table, pid)
        DynamicSupervisor.terminate_child(via_supervisor(group), pid)

      [] ->
        {:error, :not_found}
    end
  end

  @doc "Terminates all child processes in a group and removes their ETS references"
  def terminate_group(group) do
    sup = via_supervisor(group)

    :ets.lookup(@group_table, group)
    |> Enum.each(fn {^group, pid} ->
      :ets.delete(@pid_table, pid)
      DynamicSupervisor.terminate_child(sup, pid)
    end)

    :ets.delete(@group_table, group)
  end

  @doc "Returns a list of all active workers in the given group"
  def list(group \\ :default) do
    :ets.foldl(fn {^group, pid}, acc -> [pid | acc] end, [], @group_table)
  end

  @doc "Returns a list of all active workers and their groups"
  def list_all do
    :ets.foldl(fn {pid, group}, acc -> [{pid, group} | acc] end, [], @pid_table)
  end

  @doc "Returns the number of active workers in the given group"
  def count(group \\ :default) do
    :ets.lookup(@group_table, group)
    |> Enum.count()
  end

  @doc "Returns the number of active workers in all groups"
  def count_all do
    :ets.foldl(fn {_, group}, acc -> acc + count(group) end, 0, @group_table)
  end

  @doc "Sends a synchronous GenServer call to a specific pid"
  def call(pid, msg) when is_pid(pid) do
    GenServer.call(pid, msg)
  end

  @doc "Performs a guarded GenServer call to a pid under specific group"
  def call(group, pid, msg) when is_pid(pid) do
    case :ets.lookup(@pid_table, pid) do
      [{^pid, ^group}] -> GenServer.call(pid, msg)
      _ -> {:error, :not_found}
    end
  end

  @doc "Sends an asynchronous message to a specific pid"
  def cast(pid, msg) when is_pid(pid) do
    send(pid, msg)
    :ok
  end

  @doc "Sends a guarded asynchronous message to a pid in a group"
  def cast(group, pid, msg) when is_pid(pid) do
    case :ets.lookup(@pid_table, pid) do
      [{^pid, ^group}] -> send(pid, msg)
      _ -> {:error, :not_found}
    end
  end

  @doc "Sends a message to all registered pids in a group"
  def broadcast(group, msg) do
    :ets.lookup(@group_table, group)
    |> Enum.each(fn {^group, pid} -> send(pid, msg) end)
  end

  # Internal: creates or retrieves named DynamicSupervisor per group
  defp via_supervisor(group) do
    global_name = {:sup, group}

    case :global.whereis_name(global_name) do
      :undefined ->
        {:ok, _pid} =
          Poolder.DynamicSupervisor.start_link({:global, global_name}, [])

        {:global, global_name}

      _pid ->
        {:global, global_name}
    end
  end
end

defmodule Poolder.FactoryPool.Monitor do
  use GenServer

  @pid_table Poolder.FactoryPool.PidTable
  @group_table Poolder.FactoryPool.GroupTable

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def init(:ok), do: {:ok, %{}}

  def monitor(pid), do: GenServer.cast(__MODULE__, {:monitor, pid})

  def handle_cast({:monitor, pid}, state) do
    ref = Process.monitor(pid)
    {:noreply, Map.put(state, ref, pid)}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case :ets.lookup(@pid_table, pid) do
      [{^pid, group}] ->
        :ets.delete_object(@group_table, {group, pid})
        :ets.delete(@pid_table, pid)

      _ ->
        :noop
    end

    {:noreply, Map.delete(state, ref)}
  end
end
