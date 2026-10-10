defmodule Ehosctl.OutputTest do
  # Not async: capture_io(:stderr) captures stderr for every process, so tests that run
  # beside each other would read each other's errors.
  use ExUnit.Case, async: false

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

    assert capture_io(fn -> assert Output.result(result, true) == 0 end)
           |> JSON.decode!() == %{"roles" => ["a", "b"]}
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
    stdout = ExUnit.CaptureIO.capture_io(fn -> Ehosctl.Output.result(%{json: value}, true) end)

    assert stdout == ~S({"label":"a\u202Eb\u009Bc\n"}) <> "\n"
    assert JSON.decode!(stdout) == value
  end

  test "an error under --json escapes the same characters" do
    message = "a" <> <<0x202E::utf8>> <> "b"

    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn -> Ehosctl.Output.error(:invalid, message, true) end)

    assert stderr =~ ~S("message":"a\u202Eb")
    assert JSON.decode!(stderr)["error"]["message"] == message
  end
end
