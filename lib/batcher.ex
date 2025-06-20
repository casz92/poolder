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

      @behaviour Poolder.Batcher
      @compile {:inline, add: 3}

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
        spawn(__MODULE__, :run, [opts])
      end

      def start_link(opts \\ []) do
        pid = spawn_link(__MODULE__, :run, [opts])

        {:ok, pid}
      end

      def run(opts) do
        {t, c} = :edeque.new()

        # case handle_init(opts) do
        #   :ignore ->
        #     :ok

        #   _ ->
        #     # Process.register(self(), __MODULE__)
        #     loop(t, c)
        # end
        handle_init(opts)
        loop(t, c)
      end

      def push(item) do
        send(__MODULE__, {:push, item})
      end

      def push(pid, item) do
        send(pid, {:push, item})
      end

      def flush() do
        send(__MODULE__, :flush)
      end

      def flush(pid) do
        send(pid, :flush)
      end

      defp loop(t, c) do
        receive do
          {:push, item} ->
            add(t, c, item)
            loop(t, c)

          :flush ->
            flush(t, c)

          _ ->
            loop(t, c)
        after
          @batch_timeout ->
            flush(t, c)
        end
      end

      defp flush(t, c) do
        if :edeque.size(c) == 0 do
          loop(t, c)
        else
          pid = self()
          stream = :edeque.stream(t)
          state = %{table: t}
          spawn_link(__MODULE__, :try_handle_batch, [pid, stream, 1, state])
          :edeque.reset_counters(c)
          loop(:edeque.new_table(), c)
        end
      end

      if @batch_reverse do
        defp add(t, c, item) do
          :edeque.push_front(t, c, item)
        end
      else
        defp add(t, c, item) do
          :edeque.push(t, c, item)
        end
      end

      def handle_init(state), do: {:ok, state}
      def handle_batch(_batch, _state), do: :ok

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

      defoverridable handle_batch: 2, handle_init: 1
    end
  end

  @callback handle_init(state :: term) :: term
  @callback handle_batch(batch_stream :: Enumerable.t(), state :: term) :: term
end
