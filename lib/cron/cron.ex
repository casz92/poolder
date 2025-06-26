defmodule Cron do
  @moduledoc false
  import Kernel, except: [match?: 2]

  alias Cron.Calc
  alias Cron.Parser

  defstruct expression: "0 * * * * *",
            second: 0,
            minute: 0..59,
            hour: 0..23,
            day: 1..31,
            month: 1..12,
            day_of_week: 0..6

  @type t :: %Cron{
          expression: String.t(),
          second: 0..59 | [0..59, ...] | Range.t(0..59, 0..59),
          minute: 0..59 | [0..59, ...] | Range.t(0..59, 0..59),
          hour: 0..23 | [0..23, ...] | Range.t(0..23, 0..23),
          day: 1..31 | [1..31, ...] | Range.t(1..31, 1..31),
          month: 1..12 | [1..13, ...] | Range.t(1..12, 1..12),
          day_of_week: 0..6 | [0..6, ...] | Range.t(0..6, 0..6)
        }

  @type expression :: String.t()
  @type reason :: atom() | [{atom(), String.t()}]
  @type millisecond :: pos_integer()

  @doc """
  Returns an `:ok` tuple with a cron struct for the given expression string. If
  the expression is invalid an `:error` will be returned.

  Will accept expression with 6 (including `second`) and 5 (`second: 0`) fields.

  ## Examples
      iex> {:ok, cron} = Cron.new("1 2 3 * *")
      iex> cron
      #Cron<1 2 3 * *>

      iex> {:ok, cron} = Cron.new("0 1 2 3 * *")
      iex> cron
      #Cron<0 1 2 3 * *>

      iex> Cron.new("66 1 2 3 * *")
      {:error, second: "66"}
  """
  @spec new(expression()) :: {:ok, Cron.t()} | :error | {:error, reason}
  def new(string) do
    with {:ok, data} <- Parser.run(string) do
      {:ok, struct!(Cron, Keyword.put(data, :expression, string))}
    end
  end

  @doc """
  Same as `new/1`, but raises an `ArgumentError` exception in case of an invalid
  expression.
  """
  @spec new!(expression()) :: Cron.t()
  def new!(string) do
    case new(string) do
      {:ok, cron} ->
        cron

      :error ->
        raise ArgumentError, "invalid cron expression: #{inspect(string)}"

      {:error, reason} ->
        raise ArgumentError, "invalid cron expression: #{inspect(reason)}"
    end
  end

  @doc """
  Returns the next execution datetime.

  If the given `datetime` matches `cron`, then also the following datetime is
  returning. That means the resulting datetime is always greater than the given.
  The function truncates the precision of the given `datetime` to seconds.

  ## Examples

      iex> {:ok, cron} = Cron.new("0 0 0 * * *")
      iex> Cron.next(cron, ~U[2022-01-01 12:00:00Z])
      ~U[2022-01-02 00:00:00Z]
      iex> Cron.next(cron, ~U[2022-01-02 00:00:00Z])
      ~U[2022-01-03 00:00:00Z]
      iex> Cron.next(cron, ~U[2022-01-02 00:00:00.999Z])
      ~U[2022-01-03 00:00:00Z]
  """
  @spec next(Cron.t(), DateTime.t() | NaiveDateTime.t()) :: DateTime.t() | NaiveDateTime.t()
  def next(cron, datetime \\ NaiveDateTime.utc_now())

  def next(
        %Cron{} = cron,
        %DateTime{calendar: Calendar.ISO, time_zone: "Etc/UTC"} = datetime
      ) do
    cron
    |> next(DateTime.to_naive(datetime))
    |> from_naive!()
  end

  def next(%Cron{} = cron, %NaiveDateTime{calendar: Calendar.ISO} = datetime) do
    datetime
    |> NaiveDateTime.truncate(:second)
    |> Calc.next(cron)
  end

  @doc """
  Same as `next/3`, but returns the milliseconds until next execution datetime.

  ## Examples

      iex> {:ok, cron} = Cron.new("0 0 0 * * *")
      iex> Cron.until(cron, ~U[2022-01-01 12:00:00Z])
      43200000
      iex> Cron.until(cron, ~U[2022-01-02 00:00:00Z])
      86400000
      iex> Cron.until(cron, ~U[2022-01-02 00:00:00.999Z])
      86399001
  """
  @spec until(Cron.t(), DateTime.t() | NaiveDateTime.t()) :: millisecond
  def until(%Cron{} = cron, datetime \\ DateTime.utc_now()) do
    cron
    |> next(datetime)
    |> NaiveDateTime.diff(datetime, :millisecond)
  end

  def from_naive!(%NaiveDateTime{} = datetime) do
    datetime
    |> DateTime.from_naive!("Etc/UTC")
  end

  defimpl Inspect do
    @spec inspect(Cron.t(), Inspect.Opts.t()) :: String.t()
    def inspect(cron, _opts), do: "#Cron<#{cron.expression}>"
  end

  defimpl String.Chars do
    @spec to_string(Cron.t()) :: String.t()
    def to_string(%Cron{} = cron), do: cron.expression
  end
end
