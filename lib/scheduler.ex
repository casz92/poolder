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

  def start_link([crontab: crontab, name: name] = opts) do
    if crontab != [] do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      :ignore
    end
  end

  @impl true
  def init(opts) do
    crontab = Keyword.get(opts, :crontab)
    mod = Keyword.get(opts, :mod)

    trefs =
      for {key, txt} <- crontab do
        next_time = Poolder.Cron.next_run(txt)
        Process.send_after(self(), key, next_time)
      end

    {:ok, %{crontab: crontab, mod: mod, trefs: trefs}}
  end

  @impl true
  def handle_info({:kill, name}, state) do
    tref = Map.get(state.trefs, name)
    if tref, do: Process.cancel_timer(tref)
    {:noreply, %{state | trefs: Map.put(state.trefs, name, nil)}}
  end

  def handle_info({:timeout, key}, state = %{crontab: txt, mod: mod, trefs: trefs}) do
    pid = self()
    next_time = Poolder.Cron.next_run(txt)
    tref = Process.send_after(self(), key, next_time)

    spawn_link(fn ->
      try do
        case :erlang.apply(mod, key, []) do
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
