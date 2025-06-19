defmodule Poolder.Behaviour do
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

  @callback handle_periodic_job(name :: atom()) ::
              :ok
              | :stop
              | :exit
              | {:set, integer()}
              | {:set, atom(), integer()}
              | {:kill, atom()}
end
