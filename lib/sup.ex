defmodule Poolder.Supervisor do
  use Supervisor

  def start_link(children, opts \\ []) do
    name = Keyword.get(opts, :name)
    Supervisor.start_link(__MODULE__, children, name: name)
  end

  @impl true
  def init(children) do
    Supervisor.init(children, strategy: :one_for_one)
  end
end
