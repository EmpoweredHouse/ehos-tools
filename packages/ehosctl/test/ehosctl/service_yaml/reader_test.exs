defmodule Ehosctl.ServiceYaml.ReaderTest do
  use ExUnit.Case, async: true

  alias Ehosctl.ServiceYaml.Reader

  # The caller is held from when the test sees it monitor the parse until the parse has ended, so
  # no look comes while the parse nears its budget: only the parse's own count can refuse the
  # file. Under heavy load, a look before the hold could refuse it as well, which tests less but
  # never fails.
  test "refuses a parse that passed its budget and ended before the caller looked" do
    # About 28 million reductions: past the budget of 20 million, and ended within seconds.
    wide = "[" <> String.duplicate("a: ,", 3_500) <> "]"
    caller = spawn_caller(wide)

    parse = parse_of(caller)
    :erlang.suspend_process(caller)
    ref = Process.monitor(parse)

    receive do
      # Ended by itself, not killed by the heap's limit, whose refusal reads the same.
      {:DOWN, ^ref, :process, ^parse, reason} -> assert reason in [:normal, :noproc]
    end

    :erlang.resume_process(caller)

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
      nil -> flunk("the caller ended before it started the parse")
      _none_yet -> parse_of(caller)
    end
  end
end
