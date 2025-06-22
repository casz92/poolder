defmodule Poolder.Ets do
  @doc "Creates a new ETS table if it does not exist."
  def new(name, opts \\ []) do
    if :ets.whereis(name) == :undefined do
      :ets.new(name, opts)
    end
  end
end
