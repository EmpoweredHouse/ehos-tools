defmodule EhosPlatform.FailureTest do
  use ExUnit.Case, async: true

  alias EhosPlatform.Failure

  doctest Failure

  test "takes a secret out of what failed and out of what each program printed" do
    failure =
      "`kubectl` failed with exit status 1."
      |> Failure.new("kubectl", "error: rejected s3cret")
      |> Failure.added(" The password s3cret was refused.")

    assert Failure.map_text(failure, &String.replace(&1, "s3cret", "[the password]")) ==
             %Failure{
               said:
                 "`kubectl` failed with exit status 1. The password [the password] was refused.",
               tool_output: [{"kubectl", "error: rejected [the password]"}]
             }

    assert Failure.map_text("It failed: s3cret", &String.replace(&1, "s3cret", "[x]")) ==
             "It failed: [x]"
  end

  test "keeps a sentence alone when the program printed nothing but white space" do
    assert Failure.printed("`ssh` could not open the tunnel.", "ssh", " \n") ==
             "`ssh` could not open the tunnel."

    assert Failure.printed("`ssh` could not open the tunnel.", "ssh", "bind: in use\n") ==
             Failure.new("`ssh` could not open the tunnel.", "ssh", "bind: in use\n")
  end

  test "puts a sentence around a string, and around what failed with the output apart" do
    assert Failure.within("`helm` failed.", "It stopped: ", " Run it again.") ==
             "It stopped: `helm` failed. Run it again."
  end
end
