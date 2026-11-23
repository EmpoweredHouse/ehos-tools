defmodule Ehosctl.ServiceYaml.BusyTest do
  # The reader's budget counts the parser's work, not time, so a machine too busy to parse a
  # valid file within a second still reads it (ehos-tools#1066). Not async: it keeps every
  # scheduler busy, which would slow every other test.
  use ExUnit.Case, async: false

  alias Ehosctl.ServiceYaml.Reader

  test "reads a valid file while the machine is too busy to parse it within a second" do
    text = Enum.map_join(1..2_000, "", &"key#{&1}: value number #{&1}\n")
    # About 1 million reductions, or 10 ms on an idle machine; with 200 busy processes for each
    # scheduler, the parse gets about a two-hundredth of the machine, so it takes seconds.
    busy = start_busy(200 * System.schedulers_online())

    result = Reader.decode(text)
    Enum.each(busy, &Process.exit(&1, :kill))

    assert {:ok, %{"key1" => "value number 1", "key2000" => "value number 2000"}, _lines} =
             result
  end

  defp start_busy(count), do: for(_ <- 1..count, do: spawn(&busy/0))

  defp busy, do: busy()
end
