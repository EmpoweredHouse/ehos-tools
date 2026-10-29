defmodule Ehosctl.Clock do
  @moduledoc """
  The time, and waiting, as a way out (T-20): when a sign-in expires, when the update notice is
  due, how long `deploy` waits for a deployment and `logs --follow` follows a tail. A test that
  must say what time it is, or must not wait, mocks it; `Ehosctl.Case` gives every other test the
  real clock, and `Ehosctl.Case.stub_virtual_clock/0` one whose waits take no time.
  """

  @doc "Now, in UTC."
  @callback now() :: DateTime.t()

  @doc "Waits `milliseconds`, then returns `:ok`."
  @callback sleep(milliseconds :: non_neg_integer()) :: :ok

  @doc """
  Milliseconds on a clock that only moves forward, to measure how long something has taken: not
  a time of day, and comparable only with another reading of it.
  """
  @callback monotonic() :: integer()

  @impl_module Application.compile_env!(:ehosctl, [__MODULE__, :impl])

  @doc "The implementation the configuration chose."
  @spec current() :: module()
  def current, do: @impl_module
end

defmodule Ehosctl.ClockImpl do
  @moduledoc "The `Ehosctl.Clock` of this machine."

  @behaviour Ehosctl.Clock

  @impl true
  def now, do: DateTime.utc_now()

  @impl true
  def sleep(milliseconds), do: Process.sleep(milliseconds)

  @impl true
  def monotonic, do: System.monotonic_time(:millisecond)
end
