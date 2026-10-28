defmodule Ehosctl.BrowserTest do
  # `changelog --web` halts the binary right after it opens the page, so it waits for the opener
  # to return; `login` does not, since its listener must answer the browser meanwhile.
  use Ehosctl.Case, async: true

  alias Ehosctl.Browser

  @moduletag :tmp_dir

  # The opener is a script of the test's, found where `open` or `xdg-open` would be, and run for
  # real, since how long it takes is what is tested.
  setup do
    stub_with(Ehosctl.RunnerMock, Ehosctl.RunnerImpl)
    :ok
  end

  # An opener that takes a moment, as `open` and `xdg-open` do, and leaves the URL behind.
  defp opener(dir, seconds \\ "0.3") do
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

  test "waits for the opener to return when asked", %{tmp_dir: dir} do
    opened = opener(dir)
    assert Browser.open("https://github.com/x", wait: true) == :ok
    assert File.read!(opened) == "https://github.com/x"
  end

  # xdg-open with no desktop it knows runs the browser in the foreground until it is closed.
  test "waits a bounded time for an opener that does not return", %{tmp_dir: dir} do
    opened = opener(dir, "30")

    {microseconds, :ok} =
      :timer.tc(fn -> Browser.open("https://github.com/x", wait: 200) end)

    assert microseconds < 2_000_000
    refute File.exists?(opened)
  end

  test "otherwise returns at once, the opener running apart", %{tmp_dir: dir} do
    opened = opener(dir)
    assert Browser.open("https://github.com/x") == :ok
    refute File.exists?(opened)
  end
end
