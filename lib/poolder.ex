defmodule Poolder do
  defmacro __using__(opts) do
    pool_name = Keyword.fetch!(opts, :pool)
    pool_size = Keyword.get(opts, :pool_size, System.schedulers_online())
    retry = Keyword.get(opts, :retry, count: 0, backoff: 0)
    retries = Keyword.get(retry, :count)
    backoff = Keyword.get(retry, :backoff)
    callbacks = Keyword.get(opts, :callback, [])
    mode = Keyword.get(opts, :mode, :round_robin)
    crontab = Keyword.get(opts, :crontab, [])

    replies =
      for {call, {mod, fun}} <- callbacks do
        quote do
          defp reply(unquote(call), args, state) do
            :erlang.apply(unquote(mod), unquote(fun), args)
            {:noreply, state}
          end
        end
      end

    quote bind_quoted: [
            pool_name: pool_name,
            pool_size: pool_size,
            retries: retries,
            backoff: backoff,
            mode: mode,
            crontab: crontab,
            replies: replies
          ] do
      use GenServer

      @pool pool_name
      @pool_size pool_size
      @retries retries
      @backoff backoff
      @catcher @retries > 0
      @supervisor __MODULE__.Supervisor
      @mode mode

      def child_spec(id: worker_id) do
        %{
          id: {@pool, worker_id},
          start: {__MODULE__, :start_link, [worker_id]},
          type: :worker,
          restart: :transient,
          shutdown: 500
        }
      end

      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_pool, [opts]},
          type: :supervisor,
          restart: :transient,
          shutdown: 500
        }
      end

      def start_pool(_opts) do
        children =
          [
            {Registry, keys: :unique, name: @pool},
            {Poolder.Scheduler, crontab: @crontab, name: via_tuple(:scheduler), mod: __MODULE__}
          ] ++
            for i <- 0..(@pool_size - 1), do: {__MODULE__, id: i}

        case Supervisor.start_link(Poolder.Supervisor, children, name: @supervisor) do
          {:ok, pid} ->
            {:ok, pid}

          error ->
            error
        end
      end

      defp via_tuple(id), do: {:via, Registry, {@pool, id}}

      @compile {:inline, next_pid: 0, try_execute: 3}
      @behaviour Poolder.Behaviour

      def start_link(id) do
        GenServer.start_link(__MODULE__, id, name: via_tuple(id))
      end

      @impl true
      def init(id) do
        :persistent_term.put({@pool, id}, self())

        if id == 0 do
          if @mode == :round_robin do
            cref = :counters.new(1, [:write_concurrency])
            :persistent_term.put({@pool, :counter}, cref)
          end

          # Process.send_after(self(), :cleanup, @cleanup_interval)
        end

        handle_init(id)
      end

      case @mode do
        # Round-robin dispatch
        :round_robin ->
          # Reset the counter to 0
          defp reset_counter do
            cref = :persistent_term.get({@pool, :counter})
            :counters.put(cref, 0, 0)
          end

          @max_number 1_000_000
          defmacrop next_pid do
            quote do
              cref = :persistent_term.get({@pool, :counter})
              number = :counters.add(cref, 0, 1)
              key = rem(number, @pool_size)
              if number > @max_number, do: reset_counter()
              :persistent_term.get({@pool, key})
            end
          end

        # Random dispatch
        :random ->
          @range @pool_size - 1
          def next_pid, do: :rand.uniform(@range)

        # Monotonic time dispatch
        :monotonic ->
          def next_pid, do: :erlang.monotonic_time() |> abs() |> rem(@pool_size)

        # PHash dispatch
        :phash ->
          defmacrop next_pid do
            quote do
              :erlang.phash2(var!(data), @pool_size)
            end
          end
      end

      def pid(id), do: :persistent_term.get({@pool, id}, nil)

      def size, do: @pool_size

      def cast(data) do
        index = next_pid()
        pid = :persistent_term.get({@pool, index})
        GenServer.cast(pid, data)
      end

      def cast(pid, data) do
        GenServer.cast(pid, data)
      end

      def call(data, timeout \\ 5000) do
        index = next_pid()
        pid = :persistent_term.get({@pool, index})
        GenServer.call(pid, data, timeout)
      end

      @impl true
      def handle_cast(data, state) do
        try_execute(data, 1, state)
      end

      @impl true
      def handle_call(data, _from, state) do
        case handle_job(data, state) do
          {:reply, reply, new_state} -> {:reply, reply, new_state}
          _ -> {:reply, :ok, state}
        end
      end

      @impl true
      def handle_info({:retry_job, data, attempt}, state) do
        try_execute(data, attempt, state)
      end

      if replies do
        replies
      end

      defp reply(_call, _message, state), do: {:noreply, state}

      defp try_execute(data, attempt, state) when attempt <= @retries do
        try do
          case handle_job(data, state) do
            {:noreply, new_state} ->
              {:noreply, new_state}

            # Push a message
            {call, args, new_state} ->
              reply(call, args, new_state)

            # Stop the pool
            {:stop, new_state} ->
              Supervisor.stop(@supervisor, :normal)
              {:stop, :normal, new_state}

            # Close the process
            {:exit, new_state} ->
              {:stop, :normal, new_state}

            _ ->
              {:noreply, state}
          end
        rescue
          error ->
            (@catcher and
               case handle_error(data, attempt, error, state) do
                 {:retry, new_state} ->
                   try_execute(data, attempt + 1, new_state)

                 {:backoff, delay} ->
                   Process.send_after(self(), {:retry_job, data, attempt + 1}, delay)
                   {:noreply, state}

                 :halt ->
                   {:noreply, state}

                 _ ->
                   {:noreply, state}
               end) || {:noreply, state}
        end
      end

      defp try_execute(_data, _attempt, state), do: {:noreply, state}

      # Callbacks
      def handle_init(id), do: {:ok, %{id: id}}
      def handle_job(_data, state), do: {:noreply, state}

      if @backoff > 0 do
        def handle_error(_data, _attempt, _error, state), do: {:backoff, @backoff}
      else
        def handle_error(_data, _attempt, _error, state), do: {:retry, state}
      end

      def handle_periodic_job(_task), do: :ok

      defoverridable handle_init: 1, handle_job: 2, handle_error: 4, handle_periodic_job: 1
    end
  end
end
