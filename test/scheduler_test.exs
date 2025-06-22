# mix test test/scheduler_test.exs
defmodule TestTasker do
  use ExUnit.Case

  defmodule MyPeriodicJobs do
    use Poolder.Scheduler,
      name: :myjobs,
      jobs: [
        # cron style or interval style
        {:prune, "*/15 * * * * *"},
        {:update, "*/10 * * * * *"},
        {:five_seconds, 5_000}
      ],
      retry: [count: 5, backoff: 1000],
      hiberate_after: 10_000,
      # :low | :normal | :high | :max
      priority: :low

    def prune(_args) do
      IO.puts("Pruning")
    end

    def update(_args) do
      IO.puts("Updating")
    end

    def five_seconds(_args) do
      # if return {:set, :timer.hours(2)} change scheduler interval
      # if return {:set, :new_scheduler_name, "0 0 0 * * *"} create a new scheduled job
      # if return :stop, stop all scheduled jobs
      # if return :exit, stop current scheduled job
      # any other return value continue the scheduled job
      IO.puts("Five seconds")
      raise "Error in five seconds"
    end

    @impl true
    def handle_error(job_name, _attempt, error, state) do
      IO.puts("Periodic job - handle_error: #{inspect(job_name)} - #{inspect(error.message)}")
      {:retry, state}
    end

    @impl true
    def handle_hibernate(_state) do
      IO.puts("Periodic job - handle_hibernate")
    end
  end

  test "periodic jobs" do
    MyPeriodicJobs.start_link()
    Process.sleep(30_000)
  end
end
