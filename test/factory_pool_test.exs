# mix test test/factory_pool_test.exs
defmodule Poolder.FactoryPoolTest do
  use ExUnit.Case, async: true

  defmodule WillyWonkaFactory do
    use Poolder.FactoryPool
  end

  defmodule EchoWorker do
    use GenServer

    def start_link(state), do: GenServer.start_link(__MODULE__, state)

    def init(state), do: {:ok, state}

    def handle_call(:ping, _from, state), do: {:reply, :pong, state}
    def handle_info({:set, new_state}, _state), do: {:noreply, new_state}
    def handle_info(:crash, _state), do: {:stop, :normal, :ok}

    def handle_info(:print, state) do
      IO.inspect(state)
      {:noreply, state}
    end
  end

  setup do
    # Start the factory pool
    IO.puts("Starting WillyWonkaFactory")
    WillyWonkaFactory.start_link()
    :ok
  end

  test "start, call, cast, broadcast, count, terminate" do
    hersheys_group = :hersheys
    feastables_group = :feastables

    {:ok, milton} = WillyWonkaFactory.start_child(hersheys_group, {EchoWorker, %{initial: true}})

    {:ok, mrbeast} =
      WillyWonkaFactory.start_child(feastables_group, {EchoWorker, %{initial: true}})

    {:ok, nolan} = WillyWonkaFactory.start_child(feastables_group, {EchoWorker, %{initial: true}})

    assert is_pid(mrbeast)
    assert WillyWonkaFactory.count(feastables_group) == 2

    # Send a call (should reply)
    assert WillyWonkaFactory.call(milton, :ping) == :pong

    # Send a cast (no reply expected, but should not crash)
    WillyWonkaFactory.cast(
      milton,
      {:set, %{products: ["Reese's", "Snickers", "KitKat", "Kisses"]}}
    )

    # Broadcast a message
    WillyWonkaFactory.broadcast(
      feastables_group,
      {:set, %{flavors: ["Peanut Butter", "Milk Chocolate", "Cookies & creme"]}}
    )

    # Check the state of the workers
    WillyWonkaFactory.cast(milton, :print)
    WillyWonkaFactory.cast(mrbeast, :print)
    WillyWonkaFactory.cast(nolan, :print)

    # Give it a short time to crash and be removed
    WillyWonkaFactory.cast(milton, :crash)
    Process.sleep(50)

    # Terminate should now fail (already gone)
    assert {:error, :not_found} = WillyWonkaFactory.terminate(milton)

    assert WillyWonkaFactory.count(hersheys_group) == 0
    assert WillyWonkaFactory.count(feastables_group) == 2

  end
end
