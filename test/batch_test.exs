defmodule Batcher do
  require Logger

  use Poolder.Batcher,
    # batcher unique name
    name: :batcher,
    # batch size
    limit: 100,
    # batch timeout — flushes and sends the batch for processing after this time
    # interval in milliseconds or :infinity
    timeout: 10_000,
    # reverse the batch order, fifo (default) or lifo (true)
    reverse: false,
    # retry options
    retry: [count: 3, backoff: 1000]

  @impl true
  def handle_init(state) do
    {:ok, state}
  end

  @impl true
  def handle_batch(batch_stream, _state) do
    batch = Enum.to_list(batch_stream)
    IO.inspect(batch, label: "batch")
  end
end

# mix test test/batch_test.exs
defmodule TestBatch do
  use ExUnit.Case

  test "batch push and flush" do
    {:ok, pid} = Batcher.start_link([])
    Batcher.push(pid, :yellow)
    Batcher.push(pid, "Amsterdam")
    Batcher.push(pid, ["orange", "apple", "watermelon"])
    # force processing if batch is not full
    assert Batcher.flush(pid) == :flush
    Process.sleep(1000)
  end
end
