defmodule EhosPlatform.Clock do
  @moduledoc """
  Waiting, as a way out (T-20): the pauses between the checks of a server that is still booting
  or a cluster that is still changing, so a test runs them without waiting. A caller names an
  implementation in `opts[:clock]`, and `EhosPlatform.ClockImpl`, which waits, is the default.
  """

  @doc "Waits `milliseconds`, then returns `:ok`."
  @callback sleep(milliseconds :: non_neg_integer()) :: :ok
end

defmodule EhosPlatform.ClockImpl do
  @moduledoc "The `EhosPlatform.Clock` that waits, with `Process.sleep/1`."

  @behaviour EhosPlatform.Clock

  @impl true
  def sleep(milliseconds), do: Process.sleep(milliseconds)
end
