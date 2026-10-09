defmodule Ehosctl.CLI do
  @moduledoc """
  Reads the command line, runs one command and returns the exit code.

  The command line is declared once, with Optimus (T-06): each command in `commands/0`
  gives its own declaration, and help, usage and parse errors follow from it. What Optimus
  does not know is kept here: the plane each command prints in its help (eh-os D-87),
  `--json`, and the exit code of each kind of error (`Ehosctl.Output`).

  Returning the code rather than halting keeps every command testable: only
  `Ehosctl.Application` halts the VM, and only inside the binary.
  """

  alias Ehosctl.Config
  alias Ehosctl.Output

  @commands [Ehosctl.Init, Ehosctl.Installations]

  # Optimus's own default runs `tput cols`, which needs a terminal and a `tput`; help is
  # read on a terminal, and :io.columns/0 asks the one we write to.
  @default_width 80

  @doc "Every command, as the modules that implement `Ehosctl.Command`."
  @spec commands() :: [module()]
  def commands, do: @commands

  @doc """
  Runs the command `argv` names and returns its exit code.

  `opts` are what tests inject: `:commands` replaces the command line's commands, and the
  rest is handed to the command (`:config_dir`, and what `Ehosctl.Init` takes).
  """
  @spec main([String.t()], keyword()) :: non_neg_integer()
  def main(argv, opts \\ []) do
    {commands, opts} = Keyword.pop(opts, :commands, @commands)
    optimus = optimus(commands)
    json? = "--json" in argv

    case Optimus.parse(optimus, normalize(argv)) do
      {:ok, [name | path], parsed} ->
        command = Enum.find(commands, &(&1.name() == name))

        if path == [] and Keyword.has_key?(command.spec(), :subcommands) do
          say(help(optimus, commands, [name]))
        else
          command |> run(path, parsed, opts) |> finish(json?)
        end

      {:ok, _parsed} ->
        say(help(optimus, commands, []))

      :version ->
        say("ehosctl #{Ehosctl.version()}")

      :help ->
        say(help(optimus, commands, []))

      {:help, path} ->
        say(help(optimus, commands, path))

      {:error, errors} ->
        invalid(unknown_command(argv) || errors, "ehosctl --help", json?)

      {:error, path, errors} ->
        {_, [_ | names]} = Optimus.fetch_subcommand(optimus, path)
        invalid(errors, "ehosctl help #{Enum.join(names, " ")}", json?)
    end
  end

  # A governed command is handed the installation it talks to, and does not run without one
  # (T-07).
  defp run(command, path, parsed, opts) do
    if command.plane() == :governed do
      dir = Keyword.get_lazy(opts, :config_dir, &Config.dir/0)

      with {:ok, config} <- Config.read(dir),
           {:ok, installation} <- Config.select(config, parsed.options[:installation]) do
        command.call(path, parsed, Keyword.put(opts, :installation, installation))
      end
    else
      command.call(path, parsed, opts)
    end
  end

  # Optimus reads `--help` and `help <command>` only as the whole command line, so
  # `<command…> --help` and `-h`, as people type them, are turned into those first.
  defp normalize(argv) when argv in [["-h"], ["help"]], do: ["--help"]

  defp normalize(argv) do
    case Enum.split(argv, -1) do
      {[_ | _] = path, [flag]} when flag in ["--help", "-h"] -> ["help" | path]
      _ -> argv
    end
  end

  # At the top, Optimus reads a word it does not know as an argument nobody declared; a person
  # typed it as a command.
  defp unknown_command(argv) do
    case Enum.drop_while(argv, &(&1 == "help")) do
      [word | _] ->
        unless String.starts_with?(word, "-"), do: ["unknown command #{inspect(word)}"]

      [] ->
        nil
    end
  end

  defp finish(code, _json?) when is_integer(code), do: code
  defp finish({:ok, output}, json?), do: Output.result(output, json?)
  defp finish({:error, kind, message}, json?), do: Output.error(kind, message, json?)

  defp invalid(errors, hint, json?) do
    message = Enum.join(errors, "; ")
    message = if json?, do: message, else: message <> "\n\nSee `#{hint}`."
    Output.error(:invalid, message, json?)
  end

  @doc """
  The command line's declaration for Optimus, built from each of `commands`' own. Every
  governed command, and each of its subcommands, takes `--installation` (T-07).
  """
  @spec optimus([module()]) :: Optimus.t()
  def optimus(commands \\ @commands) do
    Optimus.new!(
      name: "ehosctl",
      description: "ehosctl",
      version: Ehosctl.version(),
      about: "The command-line tool for EHOS.",
      allow_unknown_args: false,
      parse_double_dash: true,
      subcommands:
        Enum.map(commands, fn command ->
          spec = Keyword.put(command.spec(), :name, Atom.to_string(command.name()))
          {command.name(), if(command.plane() == :governed, do: governed(spec), else: spec)}
        end)
    )
  end

  defp governed(spec) do
    option = [
      installation: [
        long: "--installation",
        value_name: "NAME",
        help: "The installation to talk to, instead of EHOSCTL_INSTALLATION or the current one."
      ]
    ]

    spec = Keyword.update(spec, :options, option, &(&1 ++ option))

    case spec[:subcommands] do
      nil -> spec
      subs -> Keyword.put(spec, :subcommands, Enum.map(subs, fn {k, v} -> {k, governed(v)} end))
    end
  end

  # Optimus's help, then under the top-level one what `init` creates an application from,
  # and under a command's its plane (eh-os D-87). Optimus pads every line it wraps to the
  # full width, which the trim takes off again.
  defp help(optimus, commands, path) do
    width =
      case :io.columns() do
        {:ok, columns} -> columns
        _ -> @default_width
      end

    extra =
      case path do
        [] -> template()
        [name | _] -> [plane(Enum.find(commands, &(&1.name() == name)).plane()), ""]
      end

    (Optimus.Help.help(optimus, path, width) ++ extra)
    |> Enum.map_join("\n", &String.trim_trailing(IO.chardata_to_string(&1)))
  end

  defp plane(:local), do: "Plane: local. Works on this machine alone, and needs no EHOS."

  defp plane(:governed),
    do: "Plane: governed. Acts as you, through EHOS, which decides and records every request."

  defp plane(:platform),
    do:
      "Plane: platform. Acts with an account EHOS does not issue: a cloud provider's, " <>
        "an SSH key, or a kubeconfig."

  # The pins `ehosctl init` creates an application from. `--version` prints the version
  # alone, which CI compares with the tag.
  defp template do
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

    ["Creates applications from:"] ++ lines ++ override
  end

  defp say(text) do
    IO.puts(text)
    0
  end
end
