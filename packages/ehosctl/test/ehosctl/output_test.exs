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

  test "a refusal of EHOS's prints its code beside its kind and message under --json alone" do
    refusal = %{"code" => "in_use"}

    print = fn json? ->
      capture_io(:stderr, fn -> Output.error(:failed, "In use.", json?, refusal) end)
    end

    assert JSON.decode!(print.(true)) ==
             %{"error" => %{"kind" => "failed", "message" => "In use.", "code" => "in_use"}}

    assert print.(false) == "ehosctl: In use.\n"
  end

  test "a refusal's own message is what --json prints, where the words say more" do
    refusal = %{"code" => "too_many_ephemeral", "message" => "At the count.", "cap" => 6}

    stderr =
      capture_io(:stderr, fn ->
        Output.error(:failed, "At the count.\nThe list.", true, refusal)
      end)

    assert JSON.decode!(stderr) == %{
             "error" => %{
               "kind" => "failed",
               "message" => "At the count.",
               "code" => "too_many_ephemeral",
               "cap" => 6
             }
           }
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

  describe "the shapes" do
    test "print a result as aligned lines with no colour code where stdout is no terminal" do
      text =
        Output.lines([
          Output.outcome(:done, "The server ehos-office is up."),
          Output.values([
            {"Address", "203.0.113.10"},
            {"SSH host key", "ssh-ed25519 SHA256:abc\nCompare it with the console."}
          ]),
          "",
          Output.next(["ehosctl server tunnel --installation office"])
        ])

      assert capture_io(fn -> Output.result(%{text: text, json: nil}, false) end) == """
             ✓ The server ehos-office is up.
               Address        203.0.113.10
               SSH host key   ssh-ed25519 SHA256:abc
                              Compare it with the console.

             Next:
               ehosctl server tunnel --installation office
             """
    end

    test "colour a result on a terminal, around the tags alone" do
      stub(Ehosctl.TerminalMock, :output_terminal?, fn -> true end)
      text = Output.lines([Output.outcome(:failed, "Not up."), Output.next(["ehosctl doctor"])])

      assert capture_io(fn -> Output.result(%{text: text, json: nil}, false) end) ==
               "\e[31m✗\e[0m Not up.\nNext:\n  \e[36mehosctl doctor\e[0m\n"
    end

    test "escape what a server wrote before colouring it, so its own codes never reach a terminal" do
      stub(Ehosctl.TerminalMock, :output_terminal?, fn -> true end)
      text = Output.values([{"Node", "ready\e[2J"}])

      assert capture_io(fn -> Output.result(%{text: text, json: nil}, false) end) ==
               "  \e[2mNode\e[0m   \e[1m" <> ~S("ready\u{1B}[2J") <> "\e[0m\n"
    end

    test "colour nothing when NO_COLOR holds a value, and colour when it is empty" do
      stub(Ehosctl.TerminalMock, :output_terminal?, fn -> true end)
      result = %{text: Output.outcome(:done, "Done."), json: nil}

      stub_env(%{"NO_COLOR" => "1"})
      assert capture_io(fn -> Output.result(result, false) end) == "✓ Done.\n"

      stub_env(%{"NO_COLOR" => ""})
      assert capture_io(fn -> Output.result(result, false) end) == "\e[32m✓\e[0m Done.\n"
    end

    test "never colour JSON, on a terminal too" do
      stub(Ehosctl.TerminalMock, :output_terminal?, fn -> true end)
      stub(Ehosctl.TerminalMock, :error_terminal?, fn -> true end)

      assert capture_io(fn -> Output.result(%{text: "x", json: %{"a" => 1}}, true) end) ==
               ~s({"a":1}\n)

      message = Output.lines(["No sign-in.", Output.what_to_do(["ehosctl login"])])

      assert capture_io(:stderr, fn -> Output.error(:not_signed_in, message, true) end)
             |> JSON.decode!() == %{
               "error" => %{
                 "kind" => "not_signed_in",
                 "message" => "No sign-in.\nWhat to do:\n  ehosctl login"
               }
             }
    end

    test "colour an error's prefix only where stderr is a terminal" do
      message = Output.lines(["No sign-in.", Output.what_to_do(["ehosctl login"])])

      print = fn ->
        capture_io(:stderr, fn -> Output.error(:not_signed_in, message, false) end)
      end

      assert print.() == "ehosctl: No sign-in.\nWhat to do:\n  ehosctl login\n"

      stub(Ehosctl.TerminalMock, :error_terminal?, fn -> true end)

      assert print.() ==
               "\e[31mehosctl:\e[0m No sign-in.\nWhat to do:\n  \e[36mehosctl login\e[0m\n"
    end

    test "print progress and warnings on stderr, and nothing on stdout" do
      stub(Ehosctl.TerminalMock, :error_terminal?, fn -> true end)

      {:ok, stdout} =
        with_io(fn ->
          assert capture_io(:stderr, fn ->
                   Output.progress("Making the server \e]52;c;eA==\a")
                   Output.warn("No keychain.", "The sign-in is kept in a file.\n\nIt is private.")
                 end) ==
                   "\e[2m==>\e[0m " <>
                     ~S("Making the server \u{1B}]52;c;eA==\u{7}") <>
                     "\n\e[33m! No keychain.\e[0m\n  The sign-in is kept in a file.\n\n  It is private.\n"

          :ok
        end)

      assert stdout == ""
    end

    test "frame what another program printed, each of its lines escaped on its own" do
      assert Output.tool_output("tofu", "Plan: 1\n\e[1mApply\e[0m\n")
             |> Output.render(false)
             |> IO.chardata_to_string() ==
               "tofu printed:\n  Plan: 1\n  " <> ~S("\u{1B}[1mApply\u{1B}[0m")
    end

    test "print a tag inside a tag without colour, as words and as JSON" do
      state = Output.values([{"State", Owl.Data.tag("ready", :green)}])

      assert capture_io(fn -> Output.result(%{text: state, json: nil}, false) end) ==
               "  State   ready\n"

      assert capture_io(:stderr, fn -> Output.error(:failed, state, true) end)
             |> JSON.decode!() == %{
               "error" => %{"kind" => "failed", "message" => "  State   ready"}
             }
    end

    test "put back the tags around an inner tag where it ends" do
      text = Owl.Data.tag(["a ", Owl.Data.tag("b", :bright), " c"], :yellow)

      assert text |> Output.render(true) |> IO.chardata_to_string() ==
               "\e[33ma \e[1mb\e[0m\e[33m c\e[0m"
    end
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
