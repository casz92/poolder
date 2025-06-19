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
          Process.send_after(self(), key, interval)
        }
      end

    {:ok, %{schedules: schedules, mod: mod, trefs: trefs}}
  end

  @impl true
  def handle_info({:kill, name}, state) do
    tref = Map.get(state.trefs, name)
    if tref, do: Process.cancel_timer(tref)
    {:noreply, %{state | trefs: Map.put(state.trefs, name, nil)}}
  end

  def handle_info({:timeout, key}, state = %{schedules: schedules, mod: mod, trefs: trefs}) do
    pid = self()
    interval = Map.get(schedules, key)
    tref = Process.send_after(self(), key, interval)

    spawn_link(fn ->
      try do
        case :erlang.apply(mod, key, []) do
          {:change, time} ->
            send(pid, {:change, time})

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
