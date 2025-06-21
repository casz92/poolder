defmodule Poolder.Tasker do
  @hibernate_after :infinity

  def child_spec(opts) do
    name = Keyword.get(opts, :name) || :tasker

    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :transient,
      shutdown: 500
    }
  end

  def start(opts \\ []) do
    name = Keyword.get(opts, :name) || :tasker
    pid = spawn(fn -> run(opts) end)
    Process.register(pid, name)
    {:ok, pid}
  end

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name) || :tasker
    pid = spawn_link(fn -> run(opts) end)
    Process.register(pid, name)
    {:ok, pid}
  end

  def stop(tasker) do
    send(tasker, :exit)
    :ok
  end

  @spec execute(atom() | pid(), any()) :: :ok
  def execute(tasker, msg) do
    send(tasker, {:task, {msg, nil}})
    :ok
  end

  @spec callback(atom() | pid(), any()) :: :ok
  def callback(tasker, msg) do
    pid = self()
    send(tasker, {:task, {msg, pid}})
    :ok
  end

  @spec callback(atom() | pid(), any(), pid()) :: :ok
  def callback(tasker, msg, callback_pid) do
    send(tasker, {:task, {msg, callback_pid}})
    :ok
  end

  @spec await(list(), integer()) :: list()
  def await(list, timeout \\ 5000) do
    total = Enum.count(list)

    await_loop(total, timeout, [])
  end

  defp await_loop(0, _timeout, _acc), do: []

  defp await_loop(total, timeout, acc) do
    if Enum.count(acc) >= total do
      Enum.reverse(acc)
    else
      receive do
        {:tresult, result} ->
          await_loop(total, timeout, [result | acc])
      after
        timeout ->
          Enum.reverse(acc)
      end
    end
  end

  defp run(args) do
    limit = Keyword.get(args, :limit, 5)
    hibernate_after = Keyword.get(args, :hibernate_after, @hibernate_after)
    c = :counters.new(1, [])
    loop(c, limit, :queue.new(), hibernate_after)
  end

  def loop(c, limit, queue, hibernate_after) do
    receive do
      :finished ->
        :counters.sub(c, 1, 1)

        case :queue.out(queue) do
          {:empty, _queue} ->
            loop(c, limit, queue, hibernate_after)

          {{:value, msg}, queue} ->
            run_task(c, limit, queue, msg, hibernate_after)
        end

      :exit ->
        :ok

      {:task, msg} ->
        run_task(c, limit, queue, msg, hibernate_after)

      _ ->
        loop(c, limit, queue, hibernate_after)
    after
      hibernate_after ->
        :erlang.hibernate(__MODULE__, :loop, [c, limit, queue])
    end
  end

  defp run_task(c, limit, queue, msg, hibernate_after) do
    if :counters.get(c, 1) >= limit do
      queue = :queue.in(msg, queue)
      loop(c, limit, queue, hibernate_after)
    else
      :counters.add(c, 1, 1)
      pid = self()
      {msg, from} = msg
      has_callback = from != nil

      spawn_link(fn ->
        try do
          result =
            case msg do
              {mod, fun, args} ->
                :erlang.apply(mod, fun, args)

              fun ->
                fun.()
            end

          has_callback and send(from, {:tresult, result})
        rescue
          e ->
            has_callback and send(from, {:tresult, {:error, e}})
        after
          send(pid, :finished)
        end
      end)

      loop(c, limit, queue, hibernate_after)
    end
  end
end
