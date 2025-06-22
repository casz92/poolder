defmodule Poolder.Monitor.Default do
  use Poolder.Monitor

  @impl true
  def handle_down(pid, {group_table, pid_table}) do
    case :ets.lookup(pid_table, pid) do
      [{^pid, group}] ->
        :ets.delete_object(group_table, {group, pid})
        :ets.delete(pid_table, pid)

      _ ->
        :noop
    end
  end
end
