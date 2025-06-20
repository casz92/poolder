defmodule :edeque do
  @moduledoc false

  @doc """
  A concurrent deque implemented using ETS and counters.
  Usage:
  {ets, c} = :edeque.new()
  :edeque.push(ets, c, "London")
  :edeque.push(ets, c, "New York")
  :edeque.push(ets, c, "Hong Kong")
  :edeque.push_front(ets, c, "Kyoto")
  :edeque.put(ets, c, 0, "Tokyo")
  :edeque.stream(ets) |> Enum.to_list() |> IO.inspect()
  :edeque.destroy(ets)
  """
  def new do
    ets = new_table()
    c = new_counters()
    {ets, c}
  end

  def new(name) do
    ets = new_table(name)
    c = new_counters()
    {ets, c}
  end

  def new_counters do
    :counters.new(3, [:write_concurrency])
  end

  def new_table do
    :ets.new(:deque, [:ordered_set, :public])
  end

  def new_table(name) do
    ets =
      :ets.new(name, [
        :ordered_set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

    c = :counters.new(3, [:write_concurrency])
    {ets, c}
  end

  def push(ets, c, value) do
    :counters.add(c, 2, 1)
    tail = :counters.get(c, 2)
    :counters.add(c, 3, 1)
    :ets.insert(ets, {tail, value})
  end

  def push_front(ets, c, value) do
    :counters.sub(c, 1, 1)
    head = :counters.get(c, 1)
    :counters.add(c, 3, 1)
    :ets.insert(ets, {head, value})
  end

  def put(ets, c, index, value) do
    ix = :counters.get(c, 1) + index
    :ets.insert(ets, {ix, value})
  end

  def foldl(ets, acc, fun) do
    :ets.foldl(fn {_k, v}, acc -> fun.(v, acc) end, acc, ets)
  end

  def foldr(ets, acc, fun) do
    :ets.foldr(fn {_k, v}, acc -> fun.(v, acc) end, acc, ets)
  end

  @doc """
  Returns a stream of values in the deque
  """
  def stream(ets) do
    Stream.resource(
      fn -> :ets.first(ets) end,
      fn
        :"$end_of_table" ->
          {:halt, nil}

        key ->
          case :ets.lookup(ets, key) do
            [{^key, value}] ->
              next = :ets.next(ets, key)
              {[value], next}

            [] ->
              next = :ets.next(ets, key)
              {[], next}
          end
      end,
      fn _ -> :ok end
    )
  end

  def size(c) do
    :counters.get(c, 3)
  end

  def flush(ets, c) do
    :ets.delete_all_objects(ets)
    :counters.put(c, 1, 0)
    :counters.put(c, 2, 0)
    :counters.put(c, 3, 0)
  end

  def reset_counters(c) do
    :counters.put(c, 1, 0)
    :counters.put(c, 2, 0)
    :counters.put(c, 3, 0)
  end

  def destroy(ets) do
    :ets.delete(ets)
  end
end
