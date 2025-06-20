defmodule Poolder.Worker do
  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)
    pool_size = Keyword.get(opts, :pool_size, 1)
    retry = Keyword.get(opts, :retry, count: 0, backoff: 0)
    retries = Keyword.get(retry, :count)
    backoff = Keyword.get(retry, :backoff, 0)
    callbacks = Keyword.get(opts, :callback, [])
    mode = Keyword.get(opts, :mode, :round_robin)

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
            name: name,
            pool_size: pool_size,
            retries: retries,
            backoff: backoff,
            mode: mode,
            replies: replies
          ] do
      use GenServer

      @pool name
      @pool_size pool_size
      @retries retries
      @backoff backoff
      @catcher @retries > 0
      @supervisor __MODULE__.Supervisor
      @mode mode
      @max_index @pool_size - 1
      @range 0..@max_index
      @call_timeout 5000

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
            {Registry, keys: :unique, name: @pool}
          ] ++
            for i <- @range, do: {__MODULE__, id: i}

        if @mode == :round_robin do
          cref = :counters.new(1, [:write_concurrency])
          :persistent_term.put({@pool, :counter}, cref)
        end

        case Supervisor.start_link(Poolder.Supervisor, children, name: @supervisor) do
          {:ok, pid} ->
            __MODULE__.handle_pool_ready(pid)
            {:ok, pid}

          error ->
            error
        end
      end

      defp via_tuple(id), do: {:via, Registry, {@pool, id}}

      @compile {:inline, try_execute: 3, reply: 3}
      @behaviour Poolder.Worker

      def start_link(id) do
        GenServer.start_link(__MODULE__, id, name: via_tuple(id))
      end

      @impl true
      def init(id) do
        :persistent_term.put({@pool, id}, self())
        handle_init(id)
      end

      case @mode do
        # Round-robin dispatch
        :round_robin ->
          # Reset the counter to 0
          defp reset_counter do
            cref = :persistent_term.get({@pool, :counter})
            :counters.put(cref, 1, 0)
          end

          @max_number 1_000_000
          def next_pid do
            cref = :persistent_term.get({@pool, :counter})
            :counters.add(cref, 1, 1)
            number = :counters.get(cref, 1)
            key = rem(number, @pool_size)
            if number > @max_number, do: reset_counter()
            :persistent_term.get({@pool, key})
          end

        # Random dispatch
        :random ->
          def next_pid do
            number = :rand.uniform(@pool_size) - 1
            :persistent_term.get({@pool, number})
          end

        # Monotonic time dispatch
        :monotonic ->
          def next_pid do
            number = :erlang.monotonic_time() |> abs() |> rem(@pool_size)
            :persistent_term.get({@pool, number})
          end

        # PHash dispatch
        :phash ->
          def next_pid(data) do
            number = :erlang.phash2(data, @pool_size)
            :persistent_term.get({@pool, number})
          end

        :broadcast ->
          def next_pid, do: nil

        _ ->
          raise "Invalid pool mode: #{@mode} use :round_robin, :random, :monotonic, :broadcast or :phash"
      end

      def pid(id), do: :persistent_term.get({@pool, id}, nil)

      def size, do: @pool_size

      case @mode do
        :phash ->
          def cast(data) do
            pid = next_pid(data)
            GenServer.cast(pid, data)
          end

          def call(data, timeout \\ @call_timeout) do
            try do
              pid = next_pid(data)
              {:ok, GenServer.call(pid, data, timeout)}
            catch
              :exit, {:timeout, _} -> {:error, :timeout}
              :exit, reason -> {:error, reason}
            end
          end

        :broadcast ->
          def cast(data) do
            for i <- @range do
              pid = :persistent_term.get({@pool, i})
              GenServer.cast(pid, data)
            end
          end

          def call(data, timeout \\ @call_timeout) do
            for i <- @range do
              try do
                pid = :persistent_term.get({@pool, i})
                {:ok, GenServer.call(pid, data, timeout)}
              catch
                :exit, {:timeout, _} -> {:error, :timeout}
                :exit, reason -> {:error, reason}
              end
            end
          end

        _ ->
          def cast(data) do
            pid = next_pid()
            GenServer.cast(pid, data)
          end

          def call(data, timeout \\ @call_timeout) do
            try do
              pid = next_pid()
              {:ok, GenServer.call(pid, data, timeout)}
            catch
              :exit, {:timeout, _} -> {:error, :timeout}
              :exit, reason -> {:error, reason}
            end
          end
      end

      def cast(pid, data) do
        GenServer.cast(pid, data)
      end

      @impl true
      def handle_cast(data, state) do
        try_execute(data, 1, state)
      end

      @impl true
      def handle_call(data, _from, state) do
        try_execute(data, 1, state)
      end

      @impl true
      def handle_info({:retry_job, data, attempt}, state) do
        try_execute(data, attempt, state)
      end

      if replies do
        replies
      end

      defp reply(_call, message, state), do: {:reply, message, state}

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

      def handle_pool_ready(_pid), do: :ok

      defoverridable handle_init: 1,
                     handle_job: 2,
                     handle_error: 4,
                     handle_pool_ready: 1
    end
  end

  ## Behaviour
  @callback handle_init(id :: integer()) :: {:ok, state :: any()}
  @callback handle_pool_ready(supervisor_pid :: pid()) :: any()
  @callback handle_job(data :: any(), state :: any()) ::
              {:noreply, state :: any()}
              | {:push, any(), any(), state :: any()}
              | {:reply, reply :: any(), state :: any()}
              | {:stop, reason :: any(), state :: any()}
              | {:exit, reason :: any(), state :: any()}
  @callback handle_error(data :: any(), attempt :: integer(), error :: any(), state :: any()) ::
              {:retry, state :: any()} | {:delay, integer()} | :halt
end
