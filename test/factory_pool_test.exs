# mix test test/factory_pool_test.exs
defmodule Poolder.FactoryPoolTest do
  use ExUnit.Case, async: false

  defmodule EchoWorker do
    use GenServer

    def start_link(state), do: GenServer.start_link(__MODULE__, state)

    def init(state), do: {:ok, state}

    def handle_call(:ping, _from, state), do: {:reply, :pong, state}
    def handle_info({:set, new_state}, _state), do: {:noreply, new_state}
    def handle_info(:crash, _state), do: {:stop, :normal, :ok}
  end

  setup do
    Poolder.FactoryPool.start_link()
    :ok
  end

  test "start, call, cast, broadcast, count, terminate" do
    group = :test_group

    {:ok, pid} = Poolder.FactoryPool.start_child(group, {EchoWorker, %{initial: true}})

    assert is_pid(pid)
    assert Poolder.FactoryPool.count(group) == 1

    assert Poolder.FactoryPool.call(pid, :ping) == :pong

    # Send a cast (no reply expected, but should not crash)
    assert :ok = Poolder.FactoryPool.cast(pid, {:set, %{updated: true}})

    # Broadcast a message (should not crash)
    assert :ok = Poolder.FactoryPool.broadcast(group, :crash)

    # Give it a short time to crash and be removed
    Process.sleep(50)

    # Terminate should now fail (already gone)
    assert {:error, :not_found} = Poolder.FactoryPool.terminate(pid)

    assert Poolder.FactoryPool.count(group) == 0
  end
end
