# Poolder
![Version](https://img.shields.io/badge/version-0.1.10-blue.svg)
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
  - [Building a FactoryPool](#building-a-factorypool)
  - [Building a batcher](#building-a-batcher)
- [Installation](#installation)
- [Testing](#testing)
- [License](#license)
- [Important Notice](#important-notice)

## Features
- **Fixed Pool Size**: Define the number of workers at compile time.
- **Scheduled Tasks**: Define recurring jobs at compile time with cron-style or intervals.
- **Runtime Rescheduling**: Create, reconfigure, or cancel scheduled tasks dynamically.
- **Batch message Processing**: Process multiple messages in batches.
- **Tasker**: A simple task executor for concurrent processing with limited concurrency.
- **FactoryPool**: A dynamic pool of workers with groups that can be send messages to, started and stopped at runtime.

## Callbacks
### Workers callbacks
- `handle_init/1`: Initializes the worker state.
- `handle_job/2`: Handles the job execution.
- `handle_call/3`: Handles synchronous calls.
- `handle_hibernate/1`: Handles before hibernate.
- `handle_error/4`: Handles job errors.

### Pooler callbacks
- `handle_init/1`: Handles pool ready.

### Batcher callbacks
- `handle_init/1`: Initializes the batcher state.
- `handle_batch/2`: Handles the batch processing.
- `handle_hibernate/1`: Handles before hibernate.

### Scheduler callbacks
- `handle_init/1`: Initializes the scheduler state.
- `handle_job/2`: Handles the job execution.
- `handle_error/4`: Handles job errors.
- `handle_hibernate/1`: Handles before hibernate.

## Usage

### Building a pool of workers
```elixir
defmodule MyWorker do
  use Poolder.Worker,
    # worker unique name
    name: :myworker,
    # retry options
    retry: [count: 5, backoff: 1000],
    # :low | :normal | :high | :max
    priority: :normal,
    # list of custom callbacks
    callback: [
      event: {EventBus, :notify},
      push: {Phoenix.PubSub, :broadcast},
      cast: {:websocket_client, :cast}
    ]

    @impl true
    def handle_init(state) do
      IO.puts("Worker started ##{inspect(state)} #{inspect(self())}")
      {:ok, state}
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

    @impl true
    # response updating state
    def handle_call(:get_state, _from, state) do
      {:set, state, state}
    end

    # response without updating state
    def handle_call(:hardwork, _from, state) do
      heavy_work(message)    
    end

    @impl true
    def handle_error(_data, attempt, error, state) do
      IO.puts("Error: #{inspect(error)}")

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

# Building a pool
defmodule MyPool do
  use Poolder.Pooler,
    # pool unique name
    name: :mypool,
    # initial number of workers
    pool_size: 10,
    # dynamic pool size, if true use: start_child/0, stop_child/0
    dynamic: true,
    # :round_robin | :random | :monotonic | :phash | :broadcast
    mode: :round_robin,
    # Poolder.Worker module (required)
    worker: MyWorker

  @impl true
  def handle_init(sup_pid) do
    IO.puts("Pool started ##{inspect(sup_pid)}")
  end
end
```

### Pool installation
```elixir
def MyApp.Application do
  def start(_type, _args) do
    children = [
      MyPool,
      MyBatcher,
      Poolder.Tasker, [name: :mytasker, limit: 5, hibernate_after: 60_000],
      MyPeriodicJobs,
      WillyWonkaFactory
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
    hibernate_after: 60_000,
    # :low | :normal | :high | :max
    priority: :low

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
      IO.puts("Periodic job: #{inspect(event)}")
    end

    @impl true
    def handle_hibernate(state) do
      IO.puts("Periodic job - handle_hibernate")
    end
end
```

### Building a FactoryPool
```elixir
defmodule WillyWonkaFactory do
  use Poolder.FactoryPool,
  # add this if you want to use GenServer like a child
  caller: &GenServer.call/3
end

defmodule EchoWorker do
  use GenServer

  def start_link(state), do: GenServer.start_link(__MODULE__, state)

  def init(state) do
    # Monitor process, is not necesary if you use Poolder.Worker like as child
    state.monitor.monitor(self())
    {:ok, state}
  end

  def handle_call(:ping, _from, state), do: {:reply, :pong, state}
  def handle_info({:set, new_state}, _state), do: {:noreply, new_state}
  def handle_info(:print, state) do
    IO.inspect(state)
     {:noreply, state}
  end
end

# usage
{:ok, _factory} = WillyWonkaFactory.start_link()

hersheys_group = :hersheys
feastables_group = :feastables

{:ok, milton} = WillyWonkaFactory.start_child(hersheys_group, {EchoWorker, %{initial: true}})
{:ok, mrbeast} = WillyWonkaFactory.start_child(feastables_group, {EchoWorker, %{initial: true}})
{:ok, nolan} = WillyWonkaFactory.start_child(feastables_group, {EchoWorker, %{initial: true}})
WillyWonkaFactory.count(feastables_group) == 2

# Send a call
WillyWonkaFactory.call(milton, :ping) == :pong

# Send a cast
WillyWonkaFactory.cast(milton,{:set, %{products: ["Reese's", "Snickers", "KitKat", "Kisses"]}})

# Broadcast a message
WillyWonkaFactory.broadcast(feastables_group, {:set, %{flavors: ["Peanut Butter", "Milk Chocolate", "Cookies & creme"]}})

# Check the state of the workers
WillyWonkaFactory.cast(milton, :print)
WillyWonkaFactory.cast(mrbeast, :print)
WillyWonkaFactory.cast(nolan, :print)
```

### Building a batcher
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
    # retrive the batch as a stream or list
    stream: true,
    # result with indexs {index, value}
    indexed: false,
    # retry options
    retry: [count: 3, backoff: 1000],
    # hibernate after this time in milliseconds or :infinity
    hibernate_after: 600_000,
    # :low | :normal | :high | :max
    priority: :high

  @impl true
  def handle_init(state) do
    {:ok, state}
  end

  @impl true
  def handle_batch(batch_stream, _state) do
    batch = Enum.to_list(batch_stream)
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
Batcher.push_front(pid, "Amsterdam")
Batcher.push(pid, ["red", "blue", "green"])
Batcher.pop_at(pid, 2)
Batcher.push(pid, ["orange", "apple", "watermelon"])
Batcher.flush(pid) # force processing if batch is not full
```

## Tasker
```elixir
{:ok, pid} = Tasker.start_link(name: :mytasker, limit: 2, hibernate_after: 60_000)

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
    {:poolder, "~> 0.1.10"}
  ]
end
```

## Testing
```bash
mix test test/pooler_test.exs
mix test test/factory_pool_test.exs
mix test test/batch_test.exs
mix test test/scheduler_test.exs
mix test test/tasker_test.exs
```

## License
This project is licensed under the MIT License.

---
## Important Notice

 ⚠️ This library is under active development and may undergo several changes before reaching version `0.5.0`. Some structures, functions, or behaviors may be modified or removed in future updates. If you plan to use it in production, it's recommended to pin a specific version or keep track of ongoing changes.

Thanks for being part of the journey! 🤗
