defmodule Poolder.Dispatcher do
  defmacro __using__(opts \\ []) do
    group_table = Keyword.get(opts, :group_table)
    pid_table = Keyword.get(opts, :pid_table)
    default_group = Keyword.get(opts, :default_group, :default)
    caller = Keyword.get(opts, :caller, &Poolder.call/3)
    call_timeout = Keyword.get(opts, :call_timeout, 5_000)

    quote bind_quoted: [
            group_table: group_table,
            pid_table: pid_table,
            default_group: default_group,
            caller: caller,
            call_timeout: call_timeout
          ] do
      @group_table group_table
      @pid_table pid_table
      @default_group default_group
      @caller caller
      @call_timeout call_timeout

      if @group_table == nil do
        raise "group_table is required"
      end

      if @pid_table == nil do
        raise "pid_table is required"
      end

      @behaviour Poolder.Dispatcher

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

      @doc "Sends a synchronous call to a specific pid"
      def call(pid, msg, timeout \\ @call_timeout) when is_pid(pid) do
        @caller.(pid, msg, timeout)
      end

      @doc "Performs a guarded call to a pid under specific group"
      def call(group, pid, msg, timeout) when is_pid(pid) do
        case :ets.lookup(@pid_table, pid) do
          [{^pid, ^group}] -> @caller.(pid, msg, timeout)
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
    end
  end

  @callback list(group :: atom) :: [pid]
  @callback list_all() :: [{pid, atom}]
  @callback count(group :: atom) :: non_neg_integer
  @callback count_all() :: non_neg_integer
  @callback call(pid :: pid, msg :: any, timeout :: integer) :: any
  @callback call(group :: atom, pid :: pid, msg :: any, timeout :: integer) :: any
  @callback cast(pid :: pid, msg :: any) :: :ok
  @callback cast(group :: atom, pid :: pid, msg :: any) :: :ok
  @callback broadcast(group :: atom, msg :: any) :: :ok
end

defmodule Poolder.Dispatcher.Default do
  use Poolder.Dispatcher,
    group_table: :poolder_group_table,
    pid_table: :poolder_pid_table,
    default_group: :default,
    caller: &Poolder.call/3
end
