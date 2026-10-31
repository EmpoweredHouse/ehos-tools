defmodule EhosPlatform.ClockTest do
  use ExUnit.Case, async: true
  use Hammox.Protect, module: EhosPlatform.ClockImpl, behaviour: EhosPlatform.Clock

  test "waits for as long as it is asked, then says so" do
    {elapsed_us, result} = :timer.tc(fn -> sleep(20) end)

    assert result == :ok
    assert elapsed_us >= 20_000
  end

  # Only the zone: the wall clock can step back between two reads, so an order would flake.
  test "says the time now, in UTC" do
    assert %DateTime{time_zone: "Etc/UTC"} = utc_now()
  end
end
