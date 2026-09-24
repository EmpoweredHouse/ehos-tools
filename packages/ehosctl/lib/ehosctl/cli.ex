defmodule Ehosctl.CLI do
  @moduledoc """
  Reads the command line, runs one command and returns the exit code.

  Returning the code rather than halting keeps every command testable: only
  `Ehosctl.Application` halts the VM, and only inside the binary.
  """

  @usage """
  Usage: ehosctl <command>

  Commands:
    init <name>   Create a new EHOS application in the directory <name>

  Options:
    --version     Print the version
    --help        Print this help
  """

  @flags ["--version", "--help", "-h", "help"]

  @spec main([String.t()], keyword()) :: non_neg_integer()
  def main(argv, opts \\ []) do
    case argv do
      ["init" | rest] -> Ehosctl.Init.run(rest, opts)
      ["--version"] -> say("ehosctl #{Ehosctl.version()}")
      [flag] when flag in ["--help", "-h", "help"] -> say(@usage)
      [] -> say(@usage)
      [flag | _] when flag in @flags -> fail("#{flag} takes no arguments\n\n" <> @usage)
      [unknown | _] -> fail("unknown command #{inspect(unknown)}\n\n" <> @usage)
    end
  end

  defp say(text) do
    IO.puts(text)
    0
  end

  defp fail(text) do
    IO.puts(:stderr, "ehosctl: " <> text)
    1
  end
end
