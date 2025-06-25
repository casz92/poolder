defmodule Poolder do
  @moduledoc """
  Documentation for `Poolder`.
  """

  @spec call(any(), any(), any()) :: any()
  @doc """
  Calls a function on a pooler process.

  ## Examples

      iex> Poolder.call(pid, data, 1000)
      {:ok, result}

  """
  @spec call(pid(), any(), integer()) :: {:error, any()} | any()
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
