defmodule Poolder.Worker do
  defmacro __using__(opts) do
    name = Keyword.get(opts, :name)
    pool_size = Keyword.get(opts, :pool_size, 1)
    retry = Keyword.get(opts, :retry, count: 1, backoff: 0)
    attempts = Keyword.get(retry, :count, 1)
    backoff = Keyword.get(retry, :backoff, 0)
    callbacks = Keyword.get(opts, :callback, [])
    priority = Keyword.get(opts, :priority, :normal)
    hibernate_after = Keyword.get(opts, :hibernate_after, 500)

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
            attempts: attempts,
            backoff: backoff,
            hibernate_after: hibernate_after,
            replies: replies,
            priority: priority
          ] do
      @name name || __MODULE__
      @attempts attempts
      @backoff backoff
      @catcher @attempts > 0
      @call_timeout 5000
      @priority priority
      @priority_abnormal priority != :normal
      @hibernate_after hibernate_after

      def child_spec(args) do
        %{
          id: make_ref(),
          start: {__MODULE__, :start_link, [args]},
          type: :worker,
          restart: :transient,
          shutdown: 500
        }
      end

      defp register(pid, args) when is_list(args) do
        worker_id = Keyword.get(args, :id)

        cond do
          worker_id != nil ->
            name = Keyword.get(args, :name, @name)
            :persistent_term.put({name, worker_id}, pid)
            Registry.register(name, worker_id, pid)

          true ->
            :ok
        end
      end

      defp register(_pid, _args), do: :ok

      @compile {:inline, reply: 3}
      @behaviour Poolder.Worker

      def start(args \\ []) do
        spawn(__MODULE__, :run, [args])
      end

      def start_link(args \\ []) do
        {:ok, spawn_link(__MODULE__, :run, [args])}
      end

      def run(args) do
        pid = self()
        register(pid, args)

        monitor(pid, args)
        if @priority_abnormal, do: Process.flag(:priority, @priority)
        Process.flag(:trap_exit, true)
        {:ok, state} = handle_init(args)

        loop(state, @hibernate_after)
      end

      def loop(state, hibernate_after) do
        receive do
          {:EXIT, _from, reason} ->
            terminate(reason, state)

          {:DOWN, _ref, :process, _pid, reason} ->
            terminate(reason, state)

          {:retry_job, data, attempt} ->
            try_execute(data, attempt, state, &handle_job/2, &handle_error/4)

          {:call, from, data} ->
            case handle_call(data, from, state) do
              {:reply, result, state} ->
                send(from, {:reply, result})
                loop(state, @hibernate_after)

              result ->
                send(from, {:reply, result})
                loop(state, @hibernate_after)
            end

          message ->
            try_execute(message, 1, state, &handle_job/2, &handle_error/4)
        after
          hibernate_after ->
            handle_hibernate(state)
            Process.hibernate(__MODULE__, :loop, [state, hibernate_after])
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

      if replies do
        replies
      end

      defp reply(_call, message, state), do: {:reply, message, state}

      defp try_execute(data, attempt, state, handler, error_handler) when attempt <= @attempts do
        try do
          case handler.(data, state) do
            {:ok, new_state} ->
              loop(new_state, @hibernate_after)

            {:stop, reason, new_state} ->
              terminate(reason, new_state)
              Process.exit(self(), reason)

            # Push a message
            {call, args, new_state} ->
              reply(call, args, new_state)
              loop(new_state, @hibernate_after)

            # Close the process
            {:stop, new_state} ->
              terminate(:normal, new_state)
              Process.exit(self(), :normal)

            _ ->
              loop(state, @hibernate_after)
          end
        rescue
          FunctionClauseError ->
            loop(state, @hibernate_after)

          error ->
            (@catcher and
               case error_handler.(data, attempt, error, state) do
                 {:retry, new_state} ->
                   try_execute(data, attempt + 1, new_state, handler, error_handler)

                 {:backoff, delay} ->
                   Process.send_after(self(), {:retry_job, data, attempt + 1}, delay)
                   loop(state, @hibernate_after)

                 :halt ->
                   :halt

                 _ ->
                   loop(state, @hibernate_after)
               end) || loop(state, @hibernate_after)
        end
      end

      defp try_execute(_data, _attempt, state, _handler, _error_handler),
        do: loop(state, @hibernate_after)

      # Callbacks
      def handle_init(args), do: {:ok, args}
      def handle_job(_data, state), do: {:ok, state}
      def handle_call(data, _from, state), do: {:reply, data, state}
      def handle_hibernate(_state), do: :ok
      def terminate(_reason, _state), do: :ok

      if @backoff > 0 do
        def handle_error(_data, _attempt, _error, state), do: {:backoff, @backoff}
      else
        def handle_error(_data, _attempt, _error, state), do: {:retry, state}
      end

      defoverridable handle_init: 1,
                     handle_job: 2,
                     handle_call: 3,
                     handle_error: 4,
                     handle_hibernate: 1,
                     terminate: 2
    end
  end

  ## Behaviour

  @callback handle_init(args :: any()) :: {:ok, state :: any()}
  @callback handle_job(data :: any(), state :: any()) ::
              {:ok, state :: any()}
              | {fun_callback :: atom(), args :: any(), any(), state :: any()}
              | {:stop, reply :: any(), state :: any()}
              | {:stop, state :: any()}
              | any()

  @callback handle_call(msg :: any, from :: pid, state :: any) ::
              {:reply, response :: any, state :: any} | any

  @callback handle_error(data :: any(), attempt :: integer(), error :: any(), state :: any()) ::
              {:retry, state :: any()} | {:delay, integer()} | :halt | any()
  @callback handle_hibernate(state :: any()) :: any()
  @callback terminate(reason :: any(), state :: any()) :: any()
end
