defmodule Ehosctl.BrowserTest do
  # `changelog --web` halts the binary right after it opens the page, so it waits for the opener
  # to return; `login` does not, since its listener must answer the browser meanwhile.
  use Ehosctl.Case, async: true

  alias Ehosctl.BrowserImpl

  @moduletag :tmp_dir

  # The opener is a script of the test's, found where `open` or `xdg-open` would be, and run for
  # real, since how long it takes is what is tested.
  setup do
    stub_with(Ehosctl.RunnerMock, Ehosctl.RunnerImpl)
    :ok
  end

  test "waits for the opener to return when asked", %{tmp_dir: dir} do
    opened = opener(dir)
    assert BrowserImpl.open("https://github.com/x", wait: true) == :ok
    assert File.read!(opened) == "https://github.com/x"
  end

  # xdg-open with no desktop it knows runs the browser in the foreground until it is closed.
  test "waits a bounded time for an opener that does not return", %{tmp_dir: dir} do
    opened = opener(dir, "30")

    {microseconds, :ok} =
      :timer.tc(fn -> BrowserImpl.open("https://github.com/x", wait: 200) end)

    # Half the opener's 30 seconds, which a wait without a bound would take: on a loaded machine
    # the wait of 200 ms can take seconds (ehos-tools#1020).
    assert microseconds < 15_000_000
    refute File.exists?(opened)
  end

  test "otherwise returns at once, the opener running apart", %{tmp_dir: dir} do
    opened = opener(dir)
    assert BrowserImpl.open("https://github.com/x", []) == :ok
    refute File.exists?(opened)
  end

  test "opens a page with open on macOS, and with xdg-open on another system" do
    for {type, opener} <- [{{:unix, :darwin}, "open"}, {{:unix, :linux}, "xdg-open"}] do
      mock_type(type)
      mock_find_executable(opener)
      assert BrowserImpl.open("https://github.com/x", []) == :ok
    end
  end

  # An opener that takes a moment, as `open` and `xdg-open` do, and leaves the URL behind. It is
  # not stopped when the test ends, so it lives in a directory of this run's alone: an opener of
  # an earlier run, which can end 30 seconds later, cannot write where this run reads.
  defp opener(dir, seconds \\ "0.3") do
    dir = Path.join(dir, Base.url_encode64(:crypto.strong_rand_bytes(9)))
    File.mkdir_p!(dir)
    script = Path.join(dir, "opener")

    File.write!(
      script,
      "#!/bin/sh\nsleep #{seconds}\nprintf '%s' \"$1\" > \"$(dirname \"$0\")/opened\"\n"
    )

    File.chmod!(script, 0o755)

    stub(Ehosctl.OSMock, :find_executable, fn opener when opener in ["open", "xdg-open"] ->
      script
    end)

    Path.join(dir, "opened")
  end

  defp mock_type(type), do: expect(Ehosctl.OSMock, :type, fn -> type end)

  # No opener is found, so none runs: the test reads which one was looked for.
  defp mock_find_executable(opener),
    do: expect(Ehosctl.OSMock, :find_executable, fn ^opener -> nil end)
end
