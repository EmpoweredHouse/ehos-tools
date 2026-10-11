defmodule Ehosctl.BrowserTest do
  # `changelog --web` halts the binary right after it opens the page, so it waits for the opener
  # to return; `login` does not, since its listener must answer the browser meanwhile.
  use ExUnit.Case, async: true

  alias Ehosctl.Browser

  @moduletag :tmp_dir

  # An opener that takes a moment, as `open` and `xdg-open` do, and leaves the URL behind.
  defp opener(dir, seconds \\ "0.3") do
    script = Path.join(dir, "opener")

    File.write!(
      script,
      "#!/bin/sh\nsleep #{seconds}\nprintf '%s' \"$1\" > \"$(dirname \"$0\")/opened\"\n"
    )

    File.chmod!(script, 0o755)
    {script, Path.join(dir, "opened")}
  end

  test "waits for the opener to return when asked", %{tmp_dir: dir} do
    {script, opened} = opener(dir)
    assert Browser.open("https://github.com/x", wait: true, command: script) == :ok
    assert File.read!(opened) == "https://github.com/x"
  end

  # xdg-open with no desktop it knows runs the browser in the foreground until it is closed.
  test "waits a bounded time for an opener that does not return", %{tmp_dir: dir} do
    {script, opened} = opener(dir, "30")

    {microseconds, :ok} =
      :timer.tc(fn -> Browser.open("https://github.com/x", wait: 200, command: script) end)

    assert microseconds < 2_000_000
    refute File.exists?(opened)
  end

  test "otherwise returns at once, the opener running apart", %{tmp_dir: dir} do
    {script, opened} = opener(dir)
    assert Browser.open("https://github.com/x", command: script) == :ok
    refute File.exists?(opened)
  end
end
