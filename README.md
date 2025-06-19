# Poolder

A compile-time builder that generates a concurrent pool of worker processes for parallel task execution..

## Installation

The package can be installed by adding `poolder` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:poolder, "~> 0.1.0"}
  ]
end
```

## Usage

### Building a pool
```elixir
defmodule MyPool do
  use Poolder, pool: :mypool,
   pool_size: 10,
   retry: [count: 5, backoff: 1000],
   mode: :round_robin, # :round_robin | :random | :monotonic | :phash
   callback: [
      event: {EventBus, :notify},
      push: {Phoenix.PubSub, :broadcast},
      reply: {:websocket_client, :cast}
    ]

  @impl true
  def handle_init(state) do
    {:ok, state}
  end

  @impl true
  def handle_job({:push, channel, message}, state) do
    {:push, [channel, message], state}
  end

  def handle_job({:hardwork, message}, state) do
    heavy_work(message)
  end

  def handle_job({:hardwork, message, :notify}, state) do
    result = heavy_work(message)

    event_msg = %Event{
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

  require Logger  
  @impl true
  def handle_error(_data, attempt, error, state) do
    Logger.error("Error: #{inspect(error)}")
    cond do
      # retry immediately and update state
      attempt == 1 -> {:retry, %{state | key: 5}
      # backoff for 5 seconds
      attempt == 2 -> {:backoff, 5000}
      # stop retrying
      attempt == 4 -> :halt
      # retry immediately without updating state
      true -> :something
    end
  end

  defp heavy_work(message) do
    # do something heavy
  end
end
```

### Install pool
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
