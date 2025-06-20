defmodule Poolder.Batcher do
  defmacro __using__(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    batch_limit = Keyword.get(opts, :limit, 5)
    batch_timeout = Keyword.get(opts, :timeout, :infinity)
    batch_reverse = Keyword.get(opts, :reverse, false)
    retry = Keyword.get(opts, :retry, count: 0, backoff: 0)
    retries = Keyword.get(retry, :count)
    backoff = Keyword.get(retry, :backoff, 0)

    quote bind_quoted: [
            name: name,
            batch_limit: batch_limit,
            batch_timeout: batch_timeout,
            batch_reverse: batch_reverse,
            retries: retries,
            backoff: backoff
          ] do
      @name name
      @batch_limit batch_limit
      @batch_timeout batch_timeout
      @batch_reverse batch_reverse
      @retries retries
      @backoff backoff
      @infinity batch_timeout == :infinity

      use GenServer
      @behaviour Poolder.Batcher
      @compile {:inline, add_queue: 2, add_many_queue: 2}

      # API

      def start_link(opts) do
        GenServer.start_link(__MODULE__, opts, name: @name)
      end

      def push(item) do
        GenServer.cast(__MODULE__, {:push, item})
      end

      def push(pid, item) do
        GenServer.cast(pid, {:push, item})
      end

      def push_many(items) do
        GenServer.cast(__MODULE__, {:push_many, items})
      end

      def push_many(pid, items) do
        GenServer.cast(pid, {:push_many, items})
      end

      def force_flush() do
        send(__MODULE__, :flush)
      end

      def force_flush(pid) do
        send(pid, :flush)
      end

      @impl true
      def init(_opts) do
        state = %{queue: :queue.new(), counter: :counters.new(1, []), timer: nil}
        handle_init(state)
      end

      @impl true
      if not @infinity do
        def handle_cast({:push, item}, %{queue: q, counter: c, timer: nil} = state) do
          :counters.add(c, 1, 1)
          timer = Process.send_after(self(), :flush, @batch_timeout)
          {:noreply, %{state | queue: add_queue(q, item), timer: timer}}
        end
      end

      def handle_cast({:push, item}, %{queue: q, counter: c} = state) do
        :counters.add(c, 1, 1)
        q = add_queue(q, item)

        if :counters.get(c, 1) >= @batch_limit do
          updated_state = %{state | queue: :queue.new(), timer: nil}
          flush(q, updated_state)
          cancel_timer(state.timer)
          :counters.sub(c, 1, @batch_limit)
          {:noreply, updated_state}
        else
          {:noreply, %{state | queue: q}}
        end
      end

      if not @infinity do
        def handle_cast({:push_many, items}, %{queue: q, counter: c, timer: nil} = state) do
          :counters.add(c, 1, length(items))
          timer = Process.send_after(self(), :flush, @batch_timeout)
          {:noreply, %{state | queue: add_many_queue(q, items), timer: timer}}
        end
      end

      def handle_cast({:push_many, items}, %{queue: q, counter: c} = state) do
        :counters.add(c, 1, length(items))
        q = add_many_queue(q, items)

        if :counters.get(c, 1) >= @batch_limit do
          updated_state = %{state | queue: :queue.new(), timer: nil}
          flush(q, updated_state)
          cancel_timer(state.timer)
          :counters.sub(c, 1, @batch_limit)
          {:noreply, updated_state}
        else
          {:noreply, %{state | queue: q}}
        end
      end

      @impl true
      def handle_info(:flush, %{queue: q, counter: c, timer: timer} = state) do
        cancel_timer(timer)
        updated_state = %{state | queue: :queue.new(), timer: nil}
        :counters.put(c, 1, 0)
        flush(q, updated_state)
        {:noreply, updated_state}
      end

      def handle_info({:state, state}, _state) do
        {:noreply, state}
      end

      if @batch_reverse do
        defp add_queue(q, item) do
          :queue.in(item, q)
        end

        defp add_many_queue(q, items) do
          Enum.reduce(items, q, fn item, acc -> :queue.in(item, acc) end)
        end
      else
        defp add_queue(q, item) do
          :queue.in_r(item, q)
        end

        defp add_many_queue(q, items) do
          Enum.reduce(items, q, fn item, acc -> :queue.in_r(item, acc) end)
        end
      end

      defp flush(q, state) do
        batch = :queue.to_list(q)
        pid = self()
        spawn_link(__MODULE__, :try_handle_batch, [pid, batch, 0, state])
      end

      def handle_init(state), do: {:ok, state}
      def handle_batch(_batch, state), do: {:ok, state}

      defp cancel_timer(nil), do: :ok
      defp cancel_timer(ref), do: Process.cancel_timer(ref)

      def try_handle_batch(pid, batch, attempt, state) do
        try do
          handle_batch(batch, state)
        rescue
          error ->
            if attempt < @retries do
              Process.sleep(@backoff)
              try_handle_batch(pid, batch, attempt + 1, state)
            else
              {:error, error}
            end
        end
      end

      defoverridable handle_batch: 2, handle_init: 1
    end
  end

  @callback handle_init(state :: term) :: term
  @callback handle_batch(batch :: list(), state :: term) :: term
end
