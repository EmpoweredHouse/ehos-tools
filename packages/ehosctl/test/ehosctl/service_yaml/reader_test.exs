defmodule Ehosctl.ServiceYaml.ReaderTest do
  use ExUnit.Case, async: true

  alias Ehosctl.ServiceYaml.Reader

  @over_budget {:error,
                [
                  %{
                    path: [],
                    line: nil,
                    message:
                      "the file takes more to parse than an ehos.yaml ever does; it is not read"
                  }
                ]}

  # The caller is held from when the test sees it monitor the parse until the parse has ended.
  # The caller looks first 50 ms after it starts the parse, so a prompt hold leaves only the
  # parse's own count to refuse the file. A late hold, or none when the caller has already
  # ended, lets a look refuse it, which checks less but gives the same result.
  test "refuses a parse that passed its budget and ended before the caller looked" do
    # About 1.7 million reductions, past a budget of 1 million, and far below the heap's limit.
    wide = "[" <> String.duplicate("a: ,", 500) <> "]"
    test = self()

    caller =
      spawn_link(fn -> send(test, {:decoded, Reader.decode(wide, max_reductions: 1_000_000)}) end)

    held(caller)

    decoded =
      receive do
        {:decoded, decoded} -> decoded
      end

    assert decoded == @over_budget
  end

  defp held(caller) do
    Process.flag(:priority, :high)
    parse = parse_of(caller)
    hold(caller, parse)
  end

  defp hold(_caller, nil), do: Process.flag(:priority, :normal)

  defp hold(caller, parse) do
    :erlang.suspend_process(caller)
    Process.flag(:priority, :normal)
    ref = Process.monitor(parse)

    receive do
      {:DOWN, ^ref, :process, ^parse, _reason} -> :erlang.resume_process(caller)
    end
  rescue
    # The caller ended between the test finding the parse and holding it.
    ArgumentError -> Process.flag(:priority, :normal)
  end

  # The parse is the process the caller monitors. Before it, the caller may monitor the code
  # server by its name, as it loads the reader. `nil` when the caller has ended.
  defp parse_of(caller) do
    case Process.info(caller, :monitors) do
      {:monitors, [{:process, parse}]} when is_pid(parse) -> parse
      nil -> nil
      _none_yet -> parse_of(caller)
    end
  end
end
