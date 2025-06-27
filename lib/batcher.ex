defmodule Poolder.Batcher do
  defmacro __using__(opts) do
    name = Keyword.get(opts, :name)
    batch_limit = Keyword.get(opts, :limit, 5)
    batch_timeout = Keyword.get(opts, :timeout, :infinity)
    batch_reverse = Keyword.get(opts, :reverse, false)
    batch_indexed = Keyword.get(opts, :indexed, false)
    stream = Keyword.get(opts, :stream, true)
    retry = Keyword.get(opts, :retry, count: 0, backoff: 0)
    retries = Keyword.get(retry, :count)
    backoff = Keyword.get(retry, :backoff, 0)
    hibernate_after = Keyword.get(opts, :hibernate_after, :infinity)
    priority = Keyword.get(opts, :priority, :normal)

    quote bind_quoted: [
            name: name,
            batch_limit: batch_limit,
            batch_timeout: batch_timeout,
            batch_reverse: batch_reverse,
            batch_indexed: batch_indexed,
            stream: stream,
            retries: retries,
            backoff: backoff,
            hibernate_after: hibernate_after,
            priority: priority
          ] do
      @name name || __MODULE__
      @batch_limit batch_limit
      @batch_timeout batch_timeout
      @batch_reverse batch_reverse
      @batch_indexed batch_indexed
      @stream stream
      @retries retries
      @backoff backoff
      @infinity batch_timeout == :infinity
      @hibernate_after hibernate_after
      @priority priority
      @abnormal_priority priority != :normal

      @result_fun if @stream, do: &:edeque.stream/3, else: &:edeque.to_list/3

      @behaviour Poolder.Batcher
      @compile {:inline, add: 4}

      if @hibernate_after <= @batch_timeout do
        raise ArgumentError, "#{__MODULE__} hibernate_after must be greater than batch_timeout"
      end

      # API

      def child_spec(opts \\ []) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]},
          restart: :permanent,
          type: :worker,
          shutdown: 500
        }
      end

      def start(opts \\ []) do
        pid = spawn(__MODULE__, :run, [opts])
        Process.register(pid, @name)
        {:ok, pid}
      end

      def start_link(opts \\ []) do
        pid = spawn_link(__MODULE__, :run, [opts])
        Process.register(pid, @name)

        {:ok, pid}
      end

      def run(opts) do
        {t, c} = :edeque.new()
        pid = self()

        monitor(pid, opts)
        if @abnormal_priority do
          Process.flag(:priority, @priority)
        end

        handle_init(opts)
        loop(t, c, nil)
      end

      def push(item) do
        send(__MODULE__, {:push, item})
      end

      def push(pid, item) do
        send(pid, {:push, item})
      end

      def push_front(pid, item) do
        send(pid, {:first, item})
      end

      def push_front(item) do
        send(__MODULE__, {:first, item})
      end

      def pop_at(pid, index) do
        send(pid, {:pop, index})
      end

      def flush() do
        send(__MODULE__, :flush)
      end

      def flush(pid) do
        send(pid, :flush)
      end

      def loop(t, c, tref, hibernate_after \\ @hibernate_after) do
        receive do
          {x, item} ->
            add(x, t, c, item)

            case :edeque.size(c) do
              1 ->
                tref = send_after()
                loop(t, c, tref)

              size when size < @batch_limit ->
                loop(t, c, tref)

              _ ->
                flush(t, c, tref)
            end

            if :edeque.size(c) == @batch_limit do
              flush(t, c, tref)
            else
              loop(t, c, tref)
            end

          :flush ->
            flush(t, c, tref)

          _ ->
            loop(t, c, tref)
        after
          hibernate_after ->
            handle_hibernate({t, c, tref})
            :erlang.hibernate(__MODULE__, :loop, [t, c, tref])
        end
      end

      defp do_result(t, c) do
        @result_fun.(t, c, reverse: @batch_reverse, indexed: @batch_indexed)
      end

      defp flush(t, c, tref) do
        tref = cancel_timer(tref)

        if :edeque.size(c) == 0 do
          loop(t, c, tref)
        else
          pid = self()
          messages = do_result(t, c)
          state = %{table: t}
          spawn_link(__MODULE__, :try_handle_batch, [pid, messages, 1, state])
          :edeque.reset_counters(c)
          loop(:edeque.new_table(), c, tref)
        end
      end

      defp monitor(pid, args) when is_list(args) do
        case Keyword.get(args, :monitor) do
          nil ->
            :ok

          monitor ->
            monitor.monitor(pid)
        end
      end

      defp monitor(pid, args) when is_map(args) do
        case Map.get(args, :monitor) do
          nil ->
            :ok

          monitor ->
            monitor.monitor(pid)
        end
      end

      defp monitor(_pid, _args), do: :ok

      if @infinity do
        defp send_after, do: nil
      else
        defp send_after, do: Process.send_after(self(), :flush, @batch_timeout)
      end

      defp cancel_timer(nil), do: nil

      defp cancel_timer(tref) do
        Process.cancel_timer(tref)
        nil
      end

      defp add(:push, t, c, item) do
        :edeque.push(t, c, item)
      end

      defp add(:first, t, c, item) do
        :edeque.push_front(t, c, item)
      end

      defp add(:pop, t, c, index) do
        :edeque.pop_at(t, c, index)
      end

      def handle_init(state), do: {:ok, state}
      def handle_batch(_batch, _state), do: :ok
      def handle_hibernate(_state), do: :ok

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
        after
          :ets.delete(state.table)
        end
      end

      defoverridable handle_batch: 2, handle_init: 1, handle_hibernate: 1
    end
  end

  @callback handle_init(state :: term) :: term
  @callback handle_batch(batch_stream :: Enumerable.t(), state :: term) :: term
  @callback handle_hibernate(state :: term) :: term
end
