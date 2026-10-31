defmodule EhosPlatform.ClockTest do
  use ExUnit.Case, async: true
  use Hammox.Protect, module: EhosPlatform.ClockImpl, behaviour: EhosPlatform.Clock

  test "waits for as long as it is asked, then says so" do
    {elapsed_us, result} = :timer.tc(fn -> sleep(20) end)

    assert result == :ok
    assert elapsed_us >= 20_000
  end

  # Within a minute of the system's time, either side: the wall clock can step back between two
  # reads, so comparing it with an earlier read would flake.
  test "says the time now, in UTC" do
    now = utc_now()

    assert %DateTime{time_zone: "Etc/UTC", zone_abbr: "UTC", utc_offset: 0, std_offset: 0} = now
    assert abs(DateTime.diff(now, DateTime.utc_now(), :second)) < 60
  end
end
