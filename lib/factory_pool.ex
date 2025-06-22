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

  defmacro __using__(opts) do
    name = Keyword.get(opts, :name)
    monitor = Keyword.get(opts, :monitor, Poolder.Monitor.Default)
    table = Keyword.get(opts, :table)
    supervisor = Keyword.get(opts, :supervisor, Poolder.DynamicSupervisor)
    restart = Keyword.get(opts, :restart, :transient)
    caller = Keyword.get(opts, :caller, &GenServer.call/2)

    quote bind_quoted: [
            name: name,
            monitor: monitor,
            table: table,
            caller: caller,
            supervisor: supervisor,
            restart: restart
          ] do
      @name name || __MODULE__
      @table table || __MODULE__
      # :bag — {group, pid}
      @group_table table || Module.concat(table, GroupTable)
      # :set — {pid, group}
      @pid_table Module.concat(table, PidTable)
      @caller caller
      @supervisor supervisor
      @restart restart
      @monitor monitor
      @default_group :default

      @behaviour Poolder.FactoryPool
      alias Poolder.Ets

      def child_spec(_opts) do
        %{
          id: @name,
          start: {__MODULE__, :start_link, []},
          type: :worker,
          restart: @restart,
          shutdown: 500
        }
      end

      @doc "Initializes ETS tables for group and pid tracking"
      def start_link do
        Ets.new(@group_table, [:bag, :public, :named_table, read_concurrency: true])
        Ets.new(@pid_table, [:set, :public, :named_table, read_concurrency: true])

        case @monitor.start_link({@group_table, @pid_table}) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, _pid}} ->
            :ignore
        end
      end

      @doc "Starts a worker process under a group and tracks it in ETS"
      def start_child(group, {mod, args}) do
        group = group || @default_group
        sup_name = via_supervisor(group)

        spec = %{
          id: make_ref(),
          start: {mod, :start_link, [args]},
          restart: :temporary
        }

        with {:ok, pid} <- DynamicSupervisor.start_child(sup_name, spec) do
          :ets.insert(@group_table, {group, pid})
          :ets.insert(@pid_table, {pid, group})
          @monitor.monitor(pid)
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
      def list(group \\ @default_group) do
        :ets.foldl(fn {^group, pid}, acc -> [pid | acc] end, [], @group_table)
      end

      @doc "Returns a list of all active workers and their groups"
      def list_all do
        :ets.foldl(fn {pid, group}, acc -> [{pid, group} | acc] end, [], @pid_table)
      end

      @doc "Returns the number of active workers in the given group"
      def count(group \\ @default_group) do
        :ets.lookup(@group_table, group)
        |> Enum.count()
      end

      @doc "Returns the number of active workers in all groups"
      def count_all do
        :ets.info(@group_table, :size)
      end

      @doc "Sends a synchronous GenServer call to a specific pid"
      def call(pid, msg) when is_pid(pid) do
        @caller.(pid, msg)
      end

      @doc "Performs a guarded GenServer call to a pid under specific group"
      def call(group, pid, msg) when is_pid(pid) do
        case :ets.lookup(@pid_table, pid) do
          [{^pid, ^group}] -> @caller.(pid, msg)
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
              @supervisor.start_link({:global, global_name}, [])

            {:global, global_name}

          _pid ->
            {:global, global_name}
        end
      end
    end
  end

  @callback start_link() :: {:ok, pid} | :ignore
  @callback start_child(group :: atom, {module, args :: any}) :: {:ok, pid} | {:error, any}
  @callback terminate(pid :: pid) :: :ok | {:error, any}
  @callback terminate_group(group :: atom) :: :ok | {:error, any}
  @callback list(group :: atom) :: [pid]
  @callback list_all() :: [{pid, atom}]
  @callback count(group :: atom) :: non_neg_integer
  @callback count_all() :: non_neg_integer
  @callback call(pid :: pid, msg :: any) :: any
  @callback call(group :: atom, pid :: pid, msg :: any) :: any
  @callback cast(pid :: pid, msg :: any) :: :ok
  @callback cast(group :: atom, pid :: pid, msg :: any) :: :ok
  @callback broadcast(group :: atom, msg :: any) :: :ok
end
