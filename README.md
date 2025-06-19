# Poolder

A compile-time builder that generates a concurrent pool of worker processes for parallel task execution.

### Optional Features `schedules`
- **Scheduled Tasks**: Define recurring jobs at compile time.
- **Runtime Rescheduling**: Create, reconfigure, or cancel scheduled tasks dynamically.

## Installation

The package can be installed by adding `poolder` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:poolder, "~> 0.1.3"}
  ]
end
```

## Behavior
- `handle_init/1`: Initializes the pool state.
- `handle_pool_ready/1`: Notifies when the pool is ready.
- `handle_job/2`: Handles the job execution.
- `handle_error/4`: Handles job errors.
- `handle_periodic_job/1`: Handles periodic jobs. (Scheduled jobs)

## Usage

### Building a pool
```elixir
defmodule MyPool do
  use Poolder,
    # pool name
    pool: :mypool,
    # number of workers
    pool_size: 10,
    retry: [count: 5, backoff: 1000],
    # :round_robin | :random | :monotonic | :phash | :broadcast
    mode: :round_robin,
    # list of scheduled jobs
    schedules: [
      {:every_ten_seconds, :timer.seconds(10)},
      {:pruner, :timer.hours(1)}
    ],
    # list of custom callbacks
    callback: [
      event: {EventBus, :notify},
      push: {Phoenix.PubSub, :broadcast},
      cast: {:websocket_client, :cast}
    ]

  require Logger

  @impl true
  def handle_init(state) do
    Logger.info("Worker started ##{inspect(state)} #{inspect(self())}")
    {:ok, state}
  end

  @impl true
  def handle_pool_ready(sup_pid) do
    Logger.info("Pool ready with supervisor #{inspect(sup_pid)}")
  end

  @impl true
  def handle_job({:push, channel, message}, state) do
    {:push, [channel, message], state}
  end

  def handle_job({:hardwork, message}, _state) do
    heavy_work(message)
  end

  def handle_job({:hardwork, message, :notify}, state) do
    result = heavy_work(message)

    event_msg = %EventBus.Model.Event{
      id: result.id,
      topic: :done,
      data: result
    }

    {:event, [event_msg], state}
  end

  def handle_job(:stop_worker, state) do
    {:exit, state}
  end

  def handle_job(:stop_pool, state) do
    {:stop, state}
  end

  @impl true
  def handle_error(_data, attempt, error, state) do
    Logger.error("Error: #{inspect(error)}")

    cond do
      # retry immediately and update state
      attempt == 1 -> {:retry, %{state | key: 5}}
      # backoff for 5 seconds
      attempt == 2 -> {:backoff, 5000}
      # stop retrying
      attempt == 4 -> :halt
      # retry immediately without updating state
      true -> :something
    end
  end

  ## Schedulers
  @impl true
  def handle_periodic_job(event) do
    Logger.info("Periodic job: #{inspect(event)}")
    # if return {:set, :timer.hours(2)} change scheduler interval
    # if return {:set, :new_scheduler_name, :timer.hours(2)} create a new scheduled job
    # if return :stop, stop all scheduled jobs
    # if return :exit, stop current scheduled job
    # any other return value continue the scheduled job
    :ok
  end

  ## Private functions
  defp heavy_work(message) do
    # do something heavy
    message
  end
end

```

### Pool installation
```elixir
def MyApp.Application do
  def start(_type, _args) do
    children = [
      {MyPool, []}
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

### Using pool
```elixir
# cast to random worker
message = "Hello Worker!"
MyPool.cast({:push, "lobby", message})

# cast to specific worker
index = 5
pid = MyPool.pid(index)
MyPool.cast(pid, {:hardwork, message, :notify})

# get pool size
size = MyPool.size()

for i <- 0..size-1 do
  pid = MyPool.pid(i)
  MyPool.cast(pid, {:hardwork, message})
end
```

## License
This project is licensed under the MIT License.
