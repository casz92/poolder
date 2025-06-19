defmodule Poolder.Scheduler do
  use GenServer

  def child_spec(args) do
    %{
      id: args[:name],
      start: {__MODULE__, :start_link, [args]},
      type: :worker,
      restart: :transient,
      shutdown: 500
    }
  end

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    schedules = Keyword.fetch!(opts, :schedules)

    if schedules != [] do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      :ignore
    end
  end

  @impl true
  def init(opts) do
    schedules = Keyword.get(opts, :schedules)
    mod = Keyword.get(opts, :mod)

    trefs =
      for {key, interval} <- schedules, into: %{} do
        {
          key,
          Process.send_after(self(), {:timeout, key}, interval)
        }
      end

    {:ok, %{schedules: Map.new(schedules), mod: mod, trefs: trefs}}
  end

  @impl true
  def handle_info({:kill, key}, state) do
    tref = Map.get(state.trefs, key)
    if tref, do: Process.cancel_timer(tref)
    {:noreply, %{state | trefs: Map.delete(state.trefs, key)}}
  end

  def handle_info({:set, key, new_interval}, state) do
    tref = Map.get(state.trefs, key)
    if tref, do: Process.cancel_timer(tref)
    Process.send_after(self(), {:timeout, key}, new_interval)
    {:noreply, %{state | trefs: Map.put(state.trefs, key, new_interval)}}
  end

  def handle_info({:timeout, key}, state = %{schedules: schedules, mod: mod, trefs: trefs}) do
    pid = self()
    interval = Map.get(schedules, key)
    tref = Process.send_after(self(), {:timeout, key}, interval)

    spawn_link(fn ->
      try do
        case :erlang.apply(mod, :handle_periodic_job, [key]) do
          {:set, new_interval} when interval != new_interval ->
            send(pid, {:set, key, new_interval})

          {:set, name, new_interval} ->
            send(pid, {:set, name, new_interval})

          :stop ->
            GenServer.stop(pid, :normal)

          :exit ->
            send(pid, {:kill, key})

          _ ->
            :ok
        end
      rescue
        _ -> :error
      end
    end)

    {:noreply, %{state | trefs: Map.put(trefs, key, tref)}}
  end
end
