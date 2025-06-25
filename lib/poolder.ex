defmodule Poolder do
  @moduledoc """
  Documentation for `Poolder`.
  """

  def call(pid, data, timeout) do
    try do
      send(pid, {:call, self(), data})
      do_call(timeout)
    rescue
      e ->
        {:error, e}
    end
  end

  defp do_call(timeout) do
    receive do
      {:reply, message} ->
        message

      _ ->
        do_call(timeout)
    after
      timeout ->
        {:error, :timeout}
    end
  end
end
