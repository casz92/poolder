# mix test test/pooler_test.exs
defmodule Poolder.PoolerTest do
  use ExUnit.Case, async: true

  defmodule MyWorker do
    use Poolder.Worker,
      # worker unique name
      # name: :myworker,
      # retry options
      retry: [count: 3, backoff: 1000],
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

      event_msg = %{
        id: result.id,
        topic: :done,
        data: result
      }

      {:event, [event_msg], state}
    end

    def handle_job(:stop_worker, state) do
      {:stop, state}
    end

    def handle_job(data, _state) do
      IO.puts("Worker received: #{inspect(data)}")
    end

    @impl true
    # response updating state
    def handle_call(:get_state, _from, state) do
      {:set, state, state}
    end

    # response without updating state
    def handle_call(:hardwork, _from, _state) do
      heavy_work(:hardwork)
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

  defmodule MyPool do
    use Poolder.Pooler,
      # pool unique name
      name: :mypool,
      # number of workers
      pool_size: 10,
      # allow dynamic pool size
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

  test "workers" do
    {:ok, pid} = MyWorker.start_link()
    send(pid, "If I fall, I'll stand up")
    send(pid, "I promise you will never be disappointed!")
    send(pid, "Say with me, I never gonna give up")
    assert is_pid(pid)
  end

  test "pooler" do
    {:ok, _sup_pid} = MyPool.start_pool()
    MyPool.cast(:hardwork)
    assert :hardwork = MyPool.call(:hardwork)

    if MyPool.dynamic?() do
      MyPool.start_child()
      assert 11 == MyPool.size()
      MyPool.stop_child()
      assert 10 == MyPool.size()
    end

    Process.sleep(1000)
  end
end
