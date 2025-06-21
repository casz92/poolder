# mix test test/batch_test.exs
defmodule TestTasker do
  use ExUnit.Case
  alias Poolder.Tasker

  test "execute 10 tasks awaited with Tasker" do
    {:ok, pid} = Tasker.start_link(name: :mytasker, limit: 2, hibernate_after: 60_000)

    range = 1..10

    results =
      for i <- range do
        fun = fn ->
          i * 15
        end

        Tasker.callback(pid, fun)
      end
      |> Tasker.await(:infinity)

    IO.inspect(results, label: "results")
    assert Enum.count(results) == Range.size(range)
  end

  test "execute 100 tasks asynchronously with Tasker" do
    {:ok, pid} = Tasker.start_link(name: :mytasker, limit: 2)

    range = 1..10

    for i <- range do
      fun = fn ->
        r = i * 110
        IO.puts(r)
      end

      Tasker.execute(pid, fun)
    end

    # wait for print
    :timer.sleep(1000)
    assert true
  end
end
