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
      [flag] when flag in ["--help", "-h", "help"] -> say(help())
      [] -> say(help())
      [flag | _] when flag in @flags -> fail("#{flag} takes no arguments\n\n" <> @usage)
      [unknown | _] -> fail("unknown command #{inspect(unknown)}\n\n" <> @usage)
    end
  end

  # The version, how to use it, and what `init` creates an application from. `--version` prints
  # the version alone, which CI compares with the tag.
  defp help do
    pins = Ehosctl.Template.pins()
    width = pins |> Enum.map(fn {label, _} -> String.length(label) end) |> Enum.max()

    lines =
      Enum.map(pins, fn {label, value} -> "  #{String.pad_trailing(label, width)}   #{value}" end)

    # What `init` itself would make of the variable, so the help never names a source it
    # refuses.
    override =
      case {Ehosctl.Template.source_override(), Ehosctl.Template.install_dep()} do
        {nil, _} ->
          []

        {source, {:ok, _}} ->
          ["", "  ehos_app is taken from EHOSCTL_TEMPLATE_SOURCE=#{inspect(source)} instead."]

        {source, {:error, _}} ->
          [
            "",
            "  EHOSCTL_TEMPLATE_SOURCE is #{inspect(source)}, which init refuses:",
            "  #{Ehosctl.Template.source_usage()}."
          ]
      end

    Enum.join(
      [
        "ehosctl #{Ehosctl.version()}",
        "",
        String.trim_trailing(@usage),
        "",
        "Creates applications from:"
      ] ++
        lines ++ override,
      "\n"
    )
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
