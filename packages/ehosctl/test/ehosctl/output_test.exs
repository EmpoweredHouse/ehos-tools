defmodule Ehosctl.OutputTest do
  # Not async: capture_io(:stderr) captures stderr for every process, so tests that run
  # beside each other would read each other's errors, and each test compares stderr whole.
  use Ehosctl.Case, async: false

  import ExUnit.CaptureIO

  alias Ehosctl.Output

  doctest Ehosctl.Output

  test "gives each kind of error its documented exit code, the same in every version" do
    assert Output.codes() == [
             failed: 1,
             invalid: 2,
             refused: 3,
             not_signed_in: 4,
             unreachable: 5
           ]
  end

  test "prints a result as words for a person, or as JSON" do
    result = %{text: "two roles", json: %{roles: ["a", "b"]}}

    assert capture_io(fn -> assert Output.result(result, false) == 0 end) == "two roles\n"

    assert capture_io(fn -> assert Output.result(result, true) == 0 end) ==
             ~s({"roles":["a","b"]}\n)
  end

  test "prints an error on stderr only, and returns its kind's code" do
    {code, stdout} =
      with_io(fn ->
        assert capture_io(:stderr, fn ->
                 send(self(), {:code, Output.error(:refused, "no", false)})
               end) == "ehosctl: no\n"

        assert_received {:code, code}
        code
      end)

    assert {code, stdout} == {3, ""}
  end

  test "--json escapes a bidirectional override and a C1 control, and stays the same JSON" do
    value = %{"label" => "a" <> <<0x202E::utf8>> <> "b" <> <<0x9B::utf8>> <> "c\n"}
    stdout = capture_io(fn -> Output.result(%{json: value}, true) end)

    assert stdout == ~S({"label":"a\u202Eb\u009Bc\n"}) <> "\n"
    assert JSON.decode!(stdout) == value
  end

  test "an error is printed to 64 KiB at most, whatever was added to it, cut between characters" do
    # One byte before two-byte characters puts the cut through one.
    long = "a" <> String.duplicate("é", 40_000)
    # 65,536 bytes: "refused: a" and 32,763 characters of two bytes each.
    cut_after_refused = "refused: a" <> String.duplicate("é", 32_763) <> "…"
    # 65,535 bytes: the character the cut went through is left out.
    cut = "a" <> String.duplicate("é", 32_767) <> "…"

    assert capture_io(:stderr, fn -> Output.error(:invalid, "refused: " <> long, false) end) ==
             "ehosctl: " <> cut_after_refused <> "\n"

    assert capture_io(:stderr, fn -> Output.error(:invalid, long, true) end) |> JSON.decode!() ==
             %{"error" => %{"kind" => "invalid", "message" => cut}}

    # Bytes that are not UTF-8 are kept, for the terminal's escaping to show.
    assert Output.bounded(<<0xFF>> <> long) == binary_part(<<0xFF>> <> long, 0, 65_536) <> "…"
    assert Ehosctl.Refusal.shown(long) == cut
  end

  test "an error under --json escapes the same characters" do
    message = "a" <> <<0x202E::utf8>> <> "b"

    stderr = capture_io(:stderr, fn -> Output.error(:invalid, message, true) end)

    assert stderr == ~S({"error":{"message":"a\u202Eb","kind":"invalid"}}) <> "\n"
    assert JSON.decode!(stderr) == %{"error" => %{"kind" => "invalid", "message" => message}}
  end

  test "prints an error's words escaped, and its JSON whole, bytes that are not UTF-8 included" do
    stderr =
      capture_io(:stderr, fn -> assert Output.error(:failed, "x\e[2J\n\xFF", false) == 1 end)

    assert stderr == "ehosctl: " <> ~S("x\u{1B}[2J") <> "\n" <> ~S("\xFF") <> "\n"

    stderr = capture_io(:stderr, fn -> assert Output.error(:failed, "x\xFF", true) == 1 end)
    assert JSON.decode!(stderr) == %{"error" => %{"kind" => "failed", "message" => "x�"}}
  end

  test "prints a result's words escaped, as a node a server describes" do
    stdout = capture_io(fn -> Output.result(%{text: "node \e]52;c;eA==\a", json: nil}, false) end)
    assert stdout == ~S("node \u{1B}]52;c;eA==\u{7}") <> "\n"
  end

  # ehos-tools#165: what a server or another program said reaches the terminal.
  describe "shown_lines/1" do
    test "leaves text a terminal prints as it is, Windows line ends and tabs made plain" do
      assert Output.shown_lines("one\r\ntwo\tthree\nbox ╷│╵ 🧑‍💻 می‌خواهم") ==
               "one\ntwo    three\nbox ╷│╵ 🧑‍💻 می‌خواهم"
    end

    test "quotes a line with a character a terminal acts on, escaping that character alone" do
      long = String.duplicate("a", 5000)

      for {line, shown} <- [
            {"x\e[2J", ~S("x\u{1B}[2J")},
            {"a\rb", ~S("a\u{D}b")},
            {"csi \u009B31m", ~S("csi \u{9B}31m")},
            {"rtl \u202Eevil", ~S("rtl \u{202E}evil")},
            {"tag \u{E0041}hidden", ~S("tag \u{E0041}hidden")},
            {"bad \xFF byte", ~S("bad \xFF byte")},
            {~S(say "hi" \ there) <> "\e", ~S("say \"hi\" \\ there\u{1B}")},
            {long <> "\e", "\"" <> long <> ~S(\u{1B}")}
          ] do
        assert Output.shown_lines(line) == shown
      end
    end
  end
end
