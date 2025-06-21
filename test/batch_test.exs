defmodule Batcher do
  use Poolder.Batcher,
    # batcher unique name
    name: :mybatcher,
    # batch size
    limit: 100,
    # batch timeout — flushes and sends the batch for processing after this time
    # interval in milliseconds or :infinity
    timeout: 2_000,
    # reverse the batch order, fifo (default) or lifo (true)
    reverse: true,
    # response with indexed list
    indexed: true,
    # stream the batch
    stream: true,
    # retry options
    retry: [count: 3, backoff: 1000],
    # hibernate after this time in milliseconds
    hibernate_after: 5_000

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

# mix test test/batch_test.exs
defmodule TestBatch do
  use ExUnit.Case

  test "push, push_front, pop_at and flush" do
    {:ok, pid} = Batcher.start_link([])
    Batcher.push(pid, :yellow)
    Batcher.push(:mybatcher, 5)
    Batcher.push_front(pid, "Amsterdam")
    Batcher.push(pid, ["red", "blue", "green"])
    Batcher.pop_at(pid, 2)
    Batcher.push(pid, ["orange", "apple", "watermelon"])
    # force processing if batch is not full
    assert Batcher.flush(pid) == :flush
    Process.sleep(1000)
  end

  test "timeout and hibernate" do
    {:ok, pid} = Batcher.start_link([])
    Batcher.push(pid, :red)
    Batcher.push(:mybatcher, 5)
    Batcher.push(pid, "Germany")
    Batcher.push(pid, ["Berlin", "Boston", "Belgium"])
    # wait for timeout and hibernate
    Process.sleep(8_000)
    Batcher.push(pid, "Rotterdam")
    assert Batcher.flush(pid) == :flush
    Process.sleep(1000)
  end

  test "batch push over limit" do
    {:ok, pid} = Batcher.start_link([])

    for i <- 1..200 do
      Batcher.push(pid, i)
    end

    Process.sleep(1000)
  end
end
