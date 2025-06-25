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

  defmacro __using__(opts \\ []) do
    name = Keyword.get(opts, :name)
    monitor = Keyword.get(opts, :monitor, Poolder.Monitor.Default)
    table = Keyword.get(opts, :table)
    dispatcher = Keyword.get(opts, :dispatcher, [])
    caller = Keyword.get(opts, :caller, &Poolder.call/3)
    call_timeout = Keyword.get(opts, :call_timeout, 5_000)
    supervisor = Keyword.get(opts, :supervisor, Poolder.DynamicSupervisor)
    restart = Keyword.get(opts, :restart, :transient)

    quote bind_quoted: [
            name: name,
            monitor: monitor,
            table: table,
            supervisor: supervisor,
            restart: restart,
            dispatcher: dispatcher,
            caller: caller,
            call_timeout: call_timeout
          ] do
      @name name || __MODULE__
      @table table || __MODULE__
      # :bag — {group, pid}
      @group_table Keyword.get(dispatcher, :group_table) || Module.concat(table, GroupTable)
      # :set — {pid, group}
      @pid_table Keyword.get(dispatcher, :pid_table) || Module.concat(table, PidTable)
      @default_group Keyword.get(dispatcher, :default_group) || :default

      @monitor monitor
      @supervisor supervisor
      @restart restart

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
          start: {mod, :start_link, [put_args(args, :monitor, @monitor)]},
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

      defp put_args(args, key, value) when is_list(args) do
        Keyword.put(args, key, value)
      end

      defp put_args(args, key, value) when is_map(args) do
        Map.put(args, key, value)
      end

      defp put_args(args, key, value) do
        args
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

      if dispatcher != false do
        use Poolder.Dispatcher,
          group_table: @group_table,
          pid_table: @pid_table,
          default_group: @default_group,
          caller: caller,
          call_timeout: call_timeout
      end
    end
  end

  @callback start_child(group :: atom, {module, args :: any}) :: {:ok, pid} | {:error, any}
  @callback terminate(pid :: pid) :: :ok | {:error, any}
  @callback terminate_group(group :: atom) :: :ok | {:error, any}
end
