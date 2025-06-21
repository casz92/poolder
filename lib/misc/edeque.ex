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
  :edeque.to_list(ets, indexed: true) |> IO.inspect()
  :edeque.stream(ets) |> Enum.to_list() |> IO.inspect()
  :edeque.destroy(ets)
  """
  @initial_index 0
  @counter_next 1
  @counter_prev 2
  @counter_size 3

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
    index = :counters.get(c, @counter_next)
    :counters.add(c, @counter_next, 1)
    :counters.add(c, @counter_size, 1)
    :ets.insert(ets, {index, value})
  end

  def push_front(ets, c, value) do
    :counters.sub(c, @counter_prev, 1)
    index = :counters.get(c, @counter_prev)
    :counters.add(c, @counter_size, 1)
    :ets.insert(ets, {index, value})
  end

  def put(ets, c, index, value) do
    ix = :counters.get(c, @counter_prev) + index
    :ets.insert(ets, {ix, value})
  end

  def pop_at(ets, c, index) do
    ix = :counters.get(c, @counter_prev) + index
    :ets.delete(ets, ix)
  end

  def foldl(ets, acc, fun) do
    :ets.foldl(fn {_k, v}, acc -> fun.(v, acc) end, acc, ets)
  end

  def foldr(ets, acc, fun) do
    :ets.foldr(fn {_k, v}, acc -> fun.(v, acc) end, acc, ets)
  end

  def to_list(ets, c, opts \\ []) do
    reverse = Keyword.get(opts, :reverse, false)
    indexed = Keyword.get(opts, :indexed, false)
    starts = Keyword.get(opts, :starts, 0)
    ix_total = if reverse, do: 0, else: :counters.get(c, @counter_size) - 1

    fun = if reverse, do: &:ets.foldl/3, else: &:ets.foldr/3

    fun_values =
      cond do
        indexed and reverse -> fn {_k, v}, {ix, acc} -> {ix + 1, [{ix, v} | acc]} end
        indexed and not reverse -> fn {_k, v}, {ix, acc} -> {ix - 1, [{ix, v} | acc]} end
        not indexed and reverse -> fn {_k, v}, acc -> [v | acc] end
        true -> fn {_k, v}, acc -> [v | acc] end
      end

    acc0 = if indexed, do: {ix_total + starts, []}, else: []

    fun.(fun_values, acc0, ets)
    |> then(fn
      {_, acc} -> acc
      acc -> acc
    end)
  end

  @doc """
  Returns a stream of values in the deque
  """
  def stream(ets, c, opts) do
    starts = Keyword.get(opts, :starts, 0)
    reverse = Keyword.get(opts, :reverse, false)
    indexed = Keyword.get(opts, :indexed, false)
    ix_total = :counters.get(c, @counter_size)

    start_fun =
      cond do
        reverse and indexed -> fn -> {:ets.last(ets), ix_total - 1} end
        reverse and not indexed -> fn -> :ets.last(ets) end
        indexed -> fn -> {:ets.first(ets), starts} end
        true -> fn -> :ets.first(ets) end
      end

    next_fun =
      cond do
        indexed ->
          stream_indexed_next_fun(ets, reverse)

        true ->
          stream_next_fun(ets, reverse)
      end

    Stream.resource(
      start_fun,
      next_fun,
      fn _ -> :ok end
    )
  end

  defp stream_next_fun(ets, reverse) do
    next_fun = if reverse, do: &:ets.prev/2, else: &:ets.next/2

    fn
      :"$end_of_table" ->
        {:halt, nil}

      key ->
        case :ets.lookup(ets, key) do
          [{^key, value}] ->
            next = next_fun.(ets, key)
            {[value], next}

          [] ->
            next = next_fun.(ets, key)
            {[], next}
        end
    end
  end

  defp stream_indexed_next_fun(ets, reverse) do
    next_fun = if reverse, do: &:ets.prev/2, else: &:ets.next/2
    add_fun = if reverse, do: &Kernel.-(&1, 1), else: &Kernel.+(&1, 1)

    fn
      {:"$end_of_table", index} ->
        {:halt, index}

      {key, index} ->
        case :ets.lookup(ets, key) do
          [{^key, value}] ->
            next = next_fun.(ets, key)
            ix = add_fun.(index)
            {[{index, value}], {next, ix}}

          [] ->
            next = next_fun.(ets, key)
            {[], next}
        end
    end
  end

  def size(c) do
    :counters.get(c, @counter_size)
  end

  def flush(ets, c) do
    :ets.delete_all_objects(ets)
    reset_counters(c)
  end

  def reset_counters(c) do
    :counters.put(c, @counter_next, @initial_index)
    :counters.put(c, @counter_prev, @initial_index)
    :counters.put(c, @counter_size, 0)
  end

  def destroy(ets) do
    :ets.delete(ets)
  end
end
