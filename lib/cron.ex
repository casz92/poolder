defmodule Poolder.Cron do
  def next_run(cron_string, now \\ NaiveDateTime.utc_now()) do
    [minute | _rest] = String.split(cron_string)

    next_minute =
      cond do
        minute == "*" ->
          now.minute + 1

        String.starts_with?(minute, "*/") ->
          interval = String.replace_leading(minute, "*/", "") |> String.to_integer()
          next_multiple(now.minute, interval)

        Regex.match?(~r/^\d+$/, minute) ->
          fixed_minute = String.to_integer(minute)
          if fixed_minute > now.minute, do: fixed_minute, else: fixed_minute + 60

        true ->
          raise "Formato de minuto no soportado: #{minute}"
      end

    delta = next_minute - now.minute
    next_time = NaiveDateTime.add(now, delta * 60, :second)
    DateTime.from_naive!(next_time, "Etc/UTC") |> DateTime.to_unix()
  end

  defp next_multiple(current, interval) do
    rem = rem(current, interval)
    if rem == 0, do: current + interval, else: current + (interval - rem)
  end
end
