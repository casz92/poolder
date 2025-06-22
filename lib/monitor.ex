defmodule Poolder.Monitor do
  defmacro __using__(opts) do
    name = Keyword.get(opts, :name)
    hibernate_after = Keyword.get(opts, :hibernate_after, :infinity)
    restart = Keyword.get(opts, :restart, :permanent)

    quote bind_quoted: [name: name, hibernate_after: hibernate_after, restart: restart] do
      @name name || __MODULE__
      @hibernate_after hibernate_after
      @restart restart

      @behaviour Poolder.Monitor

      def child_spec(_) do
        %{
          id: @name,
          start: {__MODULE__, :start_link, []},
          restart: @restart,
          shutdown: 5000,
          type: :worker
        }
      end

      def start(args) do
        {:ok, state} = handle_init(args)
        spawn(__MODULE__, :loop, [state])
      end

      def start_link(args) do
        case Process.whereis(@name) do
          nil ->
            {:ok, state} = handle_init(args)
            pid = spawn_link(__MODULE__, :loop, [state])
            Process.register(pid, @name)
            {:ok, pid}

          pid ->
            {:error, {:already_started, pid}}
        end
      end

      def monitor(pid) do
        :erlang.send(__MODULE__, {:monitor, pid})
        :ok
      end

      def loop(state, hibernate_after \\ @hibernate_after) do
        receive do
          {:monitor, pid} ->
            Process.monitor(pid)
            loop(state)

          {:DOWN, _ref, :process, pid, _reason} ->
            handle_down(pid, state)
            loop(state)

          _ ->
            loop(state)
        after
          hibernate_after ->
            handle_hibernate(state)
            :erlang.hibernate(__MODULE__, :loop, [state, hibernate_after])
        end
      end

      @doc "Called when the monitor starts."
      def handle_init(args), do: {:ok, args}
      @doc "Called when a monitored process goes down."
      def handle_down(_pid, _state), do: :ok
      @doc "Called when the monitor hibernates."
      def handle_hibernate(_state), do: :ok

      defoverridable handle_init: 1, handle_down: 2, handle_hibernate: 1
    end
  end

  ## Callbacks
  @callback handle_init(args :: any()) :: {:ok, any()}
  @callback handle_down(pid(), state :: any()) :: any
  @callback handle_hibernate(state :: any()) :: any
end
