defmodule EhosPlatform.Clock do
  @moduledoc """
  Waiting and the time, as a way out (T-20): the pauses between the checks of a server that is
  still booting or a cluster that is still changing, so a test runs them without waiting, and the
  time a restart is marked with, so a test says what it is. A caller names an implementation in
  `opts[:clock]`, and `EhosPlatform.ClockImpl`, which waits, is the default.
  """

  @doc "Waits `milliseconds`, then returns `:ok`."
  @callback sleep(milliseconds :: non_neg_integer()) :: :ok

  @doc "The time now, in UTC."
  @callback utc_now() :: DateTime.t()
end

defmodule EhosPlatform.ClockImpl do
  @moduledoc "The `EhosPlatform.Clock` that waits, with `Process.sleep/1`, and reads the system's time."

  @behaviour EhosPlatform.Clock

  @impl true
  def sleep(milliseconds), do: Process.sleep(milliseconds)

  @impl true
  def utc_now, do: DateTime.utc_now()
end
