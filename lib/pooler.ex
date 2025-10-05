defmodule Poolder.Pooler do
  defmacro __using__(opts \\ []) do
    quote location: :keep do
      @opts unquote(opts)
      @name @opts[:name] || __MODULE__
      @pool_size @opts[:pool_size] || 10
      @mode @opts[:mode] || :round_robin
      @dynamic @opts[:dynamic] || false
      @worker @opts[:worker] ||
                raise("`:worker` option is required. No Poolder Worker module specified")
      @call_timeout @opts[:call_timeout] || 5_000
      @supervisor_name __MODULE__.Supervisor

      @behaviour Poolder.Pooler

      if @pool_size < 1, do: raise("Pool size must be greater than 0")

      def child_spec(opts) do
        %{
          id: @name,
          start: {__MODULE__, :start_pool, [opts ++ [mode: @mode]]},
          type: :supervisor,
          restart: :transient,
          shutdown: 500
        }
      end

      def start_pool(args \\ []) do
        children =
          [
            {Registry, keys: :unique, name: @name}
          ] ++
            for i <- 0..(@pool_size - 1),
                do: {@worker, [id: i, name: @name, monitor: args[:monitor]] ++ args}

        if args[:mode] == :round_robin do
          cref = :counters.new(1, [:write_concurrency])
          :persistent_term.put({@name, :counter}, cref)
        end

        :persistent_term.put({@name, :pool_size}, @pool_size)

        if @dynamic do
          case Poolder.DynamicSupervisor.start_link(@supervisor_name, []) do
            {:ok, pid} ->
              children
              |> Enum.each(fn child ->
                {:ok, _pid} =
                  DynamicSupervisor.start_child(@supervisor_name, child)
              end)

              handle_init(pid)

              {:ok, pid}

            error ->
              error
          end
        else
          case Poolder.Supervisor.start_link(children, name: @supervisor_name) do
            {:ok, pid} ->
              handle_init(pid)
              {:ok, pid}

            error ->
              error
          end
        end
      end

      defp via_tuple, do: {:via, Registry, {@name, :sup}}

      case @mode do
        # Round-robin dispatch
        :round_robin ->
          # Reset the counter to 0
          defp reset_counter do
            cref = :persistent_term.get({@name, :counter})
            :counters.put(cref, 1, 0)
          end

          @max_number 1_000_000
          def next_pid(_data \\ nil) do
            cref = :persistent_term.get({@name, :counter})
            :counters.add(cref, 1, 1)
            number = :counters.get(cref, 1)
            key = rem(number, @pool_size)
            if number > @max_number, do: reset_counter()
            :persistent_term.get({@name, key})
          end

        # Random dispatch
        :random ->
          def next_pid(_data \\ nil) do
            number = :rand.uniform(@pool_size) - 1
            :persistent_term.get({@name, number})
          end

        # Monotonic time dispatch
        :monotonic ->
          def next_pid(_data \\ nil) do
            number = :erlang.monotonic_time() |> abs() |> rem(@pool_size)
            :persistent_term.get({@name, number})
          end

        # PHash dispatch
        :phash ->
          def next_pid(data) do
            number = :erlang.phash2(data, @pool_size)
            :persistent_term.get({@name, number})
          end

        :broadcast ->
          def next_pid(_), do: nil

        _ ->
          raise "Invalid pool mode: #{@mode} use :round_robin, :random, :monotonic, :broadcast or :phash"
      end

      def cast(data) do
        pid = next_pid(data)
        send(pid, data)
      end

      def cast(pid, data) do
        send(pid, data)
      end

      def call(data) do
        pid = next_pid(data)
        Poolder.call(pid, data, @call_timeout)
      end

      def call(pid, data, timeout \\ @call_timeout) do
        Poolder.call(pid, data, timeout)
      end

      def dynamic?, do: @dynamic

      def pid(id), do: :persistent_term.get({@name, id}, nil)

      if @dynamic do
        def size, do: :persistent_term.get({@name, :pool_size})

        def start_child(args \\ []) do
          size = size()
          index = size + 1

          DynamicSupervisor.start_child(
            @supervisor_name,
            {@worker, [id: size, name: @name] ++ args}
          )

          :persistent_term.put({@name, :pool_size}, index)
        end

        def stop_child() do
          size = size()
          index = size - 1
          pid = pid(index)
          DynamicSupervisor.terminate_child(@supervisor_name, pid)
          :persistent_term.erase({@name, size})
          :persistent_term.put({@name, :pool_size}, index)
        end
      else
        def size, do: @pool_size
      end

      def handle_init(supervisor_pid), do: :ok

      defoverridable handle_init: 1
    end
  end

  ## Behaviour
  @callback handle_init(supervisor_pid :: pid()) :: any()
end
