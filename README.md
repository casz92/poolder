# Poolder
![Version](https://img.shields.io/badge/version-0.1.7-blue.svg)
![Status](https://img.shields.io/badge/status-active-green.svg)
![License](https://img.shields.io/badge/license-MIT-blue.svg)

A compile-time builder that generates a concurrent pool of worker processes, batchers and schedulers for parallel task execution.

### Contents
- [Features](#features)
- [Behaviors](#callbacks)
  - [Workers](#workers-callbacks)
  - [Batchers](#batcher-callbacks)
  - [Schedulers](#scheduler-callbacks)
- [Usage](#usage)
  - [Building a pool of workers](#building-a-pool-of-workers)
  - [Pool installation](#pool-installation)
  - [Using pool](#using-pool)
  - [Scheduling jobs](#scheduling-jobs)
  - [Building a batcher](#building-a-batcher)
- [Installation](#installation)
- [Testing](#testing)
- [License](#license)

## Features
- **Fixed Pool Size**: Define the number of workers at compile time.
- **Scheduled Tasks**: Define recurring jobs at compile time with cron-style or intervals.
- **Runtime Rescheduling**: Create, reconfigure, or cancel scheduled tasks dynamically.
- **Batch Processing**: Aggregate and process multiple tasks in batches.
- **Tasker**: A simple task executor for concurrent processing with limited concurrency.

## Callbacks
### Workers callbacks
- `handle_init/1`: Initializes the pool state.
- `handle_pool_ready/1`: Notifies when the pool is ready.
- `handle_job/2`: Handles the job execution.
- `handle_error/4`: Handles job errors.

### Batcher callbacks
- `handle_init/1`: Initializes the batcher state.
- `handle_batch/2`: Handles the batch processing.

### Scheduler callbacks
- `handle_init/1`: Initializes the scheduler state.
- `handle_job/2`: Handles the job execution.
- `handle_error/4`: Handles job errors.


## Usage

### Building a pool of workers
```elixir
defmodule MyPool do
  use Poolder.Worker,
    # pool unique name
    name: :mypool,
    # number of workers
    pool_size: 10,
    retry: [count: 5, backoff: 1000],
    # :round_robin | :random | :monotonic | :phash | :broadcast
    mode: :round_robin,
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
      MyPool,
      MyJobs,
      MyBatcher
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

### Scheduling jobs
```elixir
defmodule MyJobs do
    use Poolder.Scheduler,
    name: :myjobs,
    jobs: [
      # cron style or interval style
      {:prune, "*/15 * * * * *"},
      {:update, "*/10 * * * * *"},
      {:five_seconds, 5_000}
    ],
    retry: [count: 5, backoff: 1000]

    def prune(_args) do
      IO.puts "Pruning"
    end

    def update(_args) do
      IO.puts "Updating"
    end

    def five_seconds(_args) do
      # if return {:set, :timer.hours(2)} change scheduler interval
      # if return {:set, :new_scheduler_name, "0 0 0 * * *"} create a new scheduled job
      # if return :stop, stop all scheduled jobs
      # if return :exit, stop current scheduled job
      # any other return value continue the scheduled job
      IO.puts "Five seconds"
    end

    @impl true
    def handle_error(_job_name, _attempt, _error, _state) do
      Logger.info("Periodic job: #{inspect(event)}")
      :ok
    end
end
```

## Building a batcher
```elixir
defmodule Batcher do
  use Poolder.Batcher,
    # batcher unique name
    name: :mybatcher,
    # batch size
    limit: 100,
    # batch timeout — flushes and sends the batch for processing after this time
    # interval in milliseconds or :infinity
    timeout: 10_000,
    # reverse the batch order, fifo (default) or lifo (true)
    reverse: false,
    # retry options
    retry: [count: 3, backoff: 1000],
    # hibernate after this time in milliseconds or :infinity
    hibernate_after: 600_000

  @impl true
  def handle_init(state) do
    {:ok, state}
  end

  @impl true
  def handle_batch(batch, _state) do
    IO.inspect(batch, label: "batch")
  end

  @impl true
  def handle_hibernate(_state) do
    IO.puts("hibernating")
  end
end

# usage
{:ok, pid} = Batcher.start_link([])
Batcher.push(pid, :yellow)
Batcher.push(:mybatcher, 5)
Batcher.push(pid, "Amsterdam")
Batcher.push(pid, ["orange", "apple", "watermelon"])
Batcher.flush(pid) # force processing if batch is not full
```

## Tasker
```elixir
{:ok, pid} = Tasker.start_link(name: :mytaker, limit: 2, hibernate_after: 60_000)

results =
  for i <- 1..100 do
    fun = fn ->
      IO.inspect(i)
    end

    Tasker.execute(pid, fun)
  end

IO.inspect(results, label: "results")
```

## Installation
Add `poolder` to your list of dependencies in `mix.exs`:
```elixir
def deps do
  [
    {:poolder, "~> 0.1.7"}
  ]
end
```

## Testing
```bash
mix test test/worker_test.exs # soon
mix test test/batcher_test.exs
mix test test/scheduler_test.exs # soon
mix test test/tasker_test.exs
```

## License
This project is licensed under the MIT License.

---
⚠️ **Important Notice**

This library is under active development and may undergo several changes before reaching version `0.5.0`. Some structures, functions, or behaviors may be modified or removed in future updates. If you plan to use it in production, it's recommended to pin a specific version or keep track of ongoing changes.

Thanks for being part of the journey! 🤗
