defmodule Poolder.Scheduler do
  defmacro __using__(opts) do
    name = Keyword.get(opts, :name)
    jobs = Keyword.get(opts, :jobs, []) |> Enum.uniq_by(&elem(&1, 0))
    retry = Keyword.get(opts, :retry, count: 10, backoff: 3000)
    retries = Keyword.get(retry, :count)
    backoff = Keyword.get(retry, :backoff, 1000)
    hibernate_after = Keyword.get(opts, :hibernate_after, :infinity)
    priority = Keyword.get(opts, :priority, 0)

    quote bind_quoted: [
            name: name,
            jobs: jobs,
            retries: retries,
            backoff: backoff,
            hibernate_after: hibernate_after,
            priority: priority
          ] do
      @name name || __MODULE__
      @jobs jobs
      @retries retries
      @backoff backoff
      @catcher retries > 0
      @hibernate_after hibernate_after
      @priority priority
      @priority_abnormal priority != :normal

      if @jobs == [] do
        raise "Scheduler #{name} has no jobs"
      end

      @behaviour Poolder.Scheduler

      def child_spec(args) do
        %{
          id: @name,
          start: {__MODULE__, :start_link, [args]},
          type: :worker,
          restart: :transient,
          shutdown: 500
        }
      end

      def start(opts \\ []) do
        pid = spawn(__MODULE__, :run, [opts])
        Process.register(pid, @name)
        {:ok, pid}
      end

      def start_link(opts \\ []) do
        pid = spawn_link(__MODULE__, :run, [opts])
        Process.register(pid, @name)
        {:ok, pid}
      end

      def run(opts) do
        trefs =
          for {key, interval} <- @jobs, into: %{} do
            {
              key,
              send_after(key, interval)
            }
          end

        args = %{jobs: Map.new(@jobs), trefs: trefs, opts: opts}
        loop(args)
      end

      def loop(state, hibernate_after \\ @hibernate_after) do
        receive do
          {:kill, key} ->
            handle_info({:kill, key}, state)

          {:set, key, interval} ->
            handle_info({:set, key, interval}, state)

          {:timeout, key} ->
            handle_info({:timeout, key}, state)

          {:retry_job, key, attempt} ->
            handle_info({:retry_job, key, attempt}, state)

          _ ->
            :ignore
        after
          hibernate_after ->
            handle_hibernate(state)
            :erlang.hibernate(__MODULE__, :loop, [state])
        end
      end

      defp handle_info({:kill, key}, state) do
        tref = Map.get(state.trefs, key)
        cancel_timer(tref)
        loop(%{state | trefs: Map.delete(state.trefs, key)})
      end

      defp handle_info({:set, key, interval}, state) do
        tref = Map.get(state.trefs, key)
        cancel_timer(tref)
        tref = send_after(key, interval)
        loop(%{state | trefs: Map.put(state.trefs, key, tref)})
      end

      defp handle_info({:timeout, key}, state = %{jobs: jobs, trefs: trefs}) do
        pid = self()
        interval = Map.get(jobs, key)
        tref = send_after(key, interval)

        spawn_link(__MODULE__, :try_run, [pid, key, 1, state])

        loop(%{state | trefs: Map.put(trefs, key, tref)})
      end

      defp handle_info({:retry_job, key, attempt}, state) do
        try_run(self(), key, attempt, state)
        loop(state)
      end

      ## Public API
      def stop(task) do
        send(__MODULE__, {:kill, task})
      end

      def schedule(task, interval) do
        send(__MODULE__, {:set, task, interval})
      end

      def try_run(pid, key, attempt, state) when attempt <= @retries do
        try do
          if @priority_abnormal, do: :erlang.process_flag(:priority, @priority)

          case :erlang.apply(__MODULE__, key, [state]) do
            {:set, new_interval} ->
              send(pid, {:set, key, new_interval})

            {:set, name, new_interval} ->
              send(pid, {:set, name, new_interval})

            {:kill, key} ->
              send(pid, {:kill, key})

            :kill ->
              send(pid, {:kill, key})

            :stop ->
              Process.exit(pid, :normal)

            _ ->
              :ok
          end
        rescue
          error ->
            @catcher and
              case handle_error(key, attempt, error, state) do
                {:retry, new_state} ->
                  try_run(pid, key, attempt + 1, new_state)

                {:backoff, delay} ->
                  Process.send_after(pid, {:retry_job, key, attempt + 1}, delay)

                _halt ->
                  :ok
              end
        end
      end

      def try_run(_pid, _key, _attempt, _state), do: :ok

      if @backoff > 0 do
        def handle_error(_key, _attempt, _error, state), do: {:backoff, @backoff}
      else
        def handle_error(_key, _attempt, _error, state), do: {:retry, state}
      end

      def handle_hibernate(_state), do: :ok

      defoverridable stop: 1, schedule: 2, handle_error: 4, handle_hibernate: 1

      ## Private API
      defp cancel_timer(nil), do: :ok
      defp cancel_timer(tref), do: Process.cancel_timer(tref)

      defp send_after(key, interval) do
        case next_interval(interval) do
          :error ->
            nil

          next_interval ->
            Process.send_after(self(), {:timeout, key}, next_interval)
        end
      end

      defp next_interval(cron) when is_binary(cron) do
        case Cron.new(cron) do
          {:ok, cron} ->
            Cron.until(cron, DateTime.utc_now())

          {:error, _} ->
            :error
        end
      end

      defp next_interval(x) when is_integer(x), do: x

      defp next_interval(:year), do: 31_536_000_000
      defp next_interval(:month), do: 2_592_000_000
      defp next_interval(:week), do: 604_800_000
      defp next_interval(:day), do: 86_400_000
      defp next_interval(:hour), do: 3_600_000
      defp next_interval(:minute), do: 60_000
      defp next_interval(:second), do: 1_000
      defp next_interval(_), do: :error
    end
  end

  @callback handle_hibernate(state :: any) :: any

  @callback handle_error(job :: term, attempt :: integer, error :: any, state :: any) ::
              {:retry, new_state :: any}
              | {:backoff, delay :: integer}
              | :halt
end
