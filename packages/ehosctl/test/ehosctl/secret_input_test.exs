defmodule Ehosctl.SecretInputTest do
  use Ehosctl.Case, async: true

  alias Ehosctl.SecretInput

  @moduletag :tmp_dir

  @texts %{
    subject: "The password",
    of: "the password",
    most: "the most that ehosctl reads",
    nothing: "ehosctl changed nothing.",
    from: "Give a file.",
    advice: "Pipe it:",
    to_do: ["pbpaste | ehosctl resources add-database ledger --password-file -"]
  }

  test "reads a file as it holds it", %{tmp_dir: dir} do
    path = Path.join(dir, "password.txt")
    File.write!(path, "s3cret\n")
    assert SecretInput.read(path, 64, @texts) == {:ok, "s3cret\n"}
  end

  # As `--from-file <(…)` gives a path: a pipe, which is read.
  test "reads a pipe that a path names", %{tmp_dir: dir} do
    path = Path.join(dir, "fifo")
    {_output, 0} = System.cmd("mkfifo", [path])

    # A writer outside the VM, as the shell is for `<(…)`.
    Port.open({:spawn_executable, "/bin/sh"}, [
      :binary,
      args: ["-c", ~s(printf s3cret > "$0"), path]
    ])

    assert SecretInput.read(path, 64, @texts) == {:ok, "s3cret"}
  end

  # `/dev/tty`, or `/dev/stdin` at a terminal, would be a terminal read with echo on.
  test "refuses a path to a device, as it refuses a terminal" do
    refused =
      {:error, :invalid,
       %Ehosctl.Failure{
         said: "ehosctl changed nothing.",
         reason:
           "ehosctl does not read the password from a terminal, which can show or keep it. " <>
             "Give a file.",
         advice: "Pipe it:",
         to_do: ["pbpaste | ehosctl resources add-database ledger --password-file -"]
       }}

    assert SecretInput.read("/dev/null", 64, @texts) == refused

    stub(Ehosctl.TerminalMock, :input_terminal?, fn -> true end)
    assert SecretInput.read(:stdin, 64, @texts) == refused
  end
end
