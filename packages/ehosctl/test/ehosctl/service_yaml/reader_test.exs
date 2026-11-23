defmodule Ehosctl.ServiceYaml.ReaderTest do
  use ExUnit.Case, async: true

  alias Ehosctl.ServiceYaml.Reader

  # The caller is held while the parse runs, so it never looks at the parse: only the parse's own
  # count of its work can refuse the file.
  test "refuses a parse that passed its budget and ended before the caller looked" do
    # About 28 million reductions: past the budget of 20 million, and ended within seconds.
    wide = "[" <> String.duplicate("a: ,", 3_500) <> "]"
    caller = spawn_caller(wide)

    parse = parse_of(caller)
    :erlang.suspend_process(caller)
    ref = Process.monitor(parse)

    receive do
      {:DOWN, ^ref, :process, ^parse, _reason} -> :erlang.resume_process(caller)
    end

    decoded =
      receive do
        {:decoded, decoded} -> decoded
      end

    assert decoded ==
             {:error,
              [
                %{
                  path: [],
                  line: nil,
                  message:
                    "the file takes more to parse than an ehos.yaml ever does; it is not read"
                }
              ]}
  end

  defp spawn_caller(text) do
    test = self()
    spawn_link(fn -> send(test, {:decoded, Reader.decode(text)}) end)
  end

  # The parse is the process the caller monitors. Before it, the caller may monitor the code
  # server by its name, as it loads the reader.
  defp parse_of(caller) do
    case Process.info(caller, :monitors) do
      {:monitors, [{:process, parse}]} when is_pid(parse) -> parse
      _none_yet -> parse_of(caller)
    end
  end
end
