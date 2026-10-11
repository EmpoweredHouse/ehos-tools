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

  @commands [
    Ehosctl.Init,
    Ehosctl.Installations,
    Ehosctl.Login,
    Ehosctl.Logout,
    Ehosctl.Whoami,
    Ehosctl.Roles,
    Ehosctl.Apps,
    Ehosctl.Credential,
    Ehosctl.Call,
    Ehosctl.People,
    Ehosctl.Deploy,
    Ehosctl.Env,
    Ehosctl.Resources,
    Ehosctl.RoleBindings,
    Ehosctl.Audit,
    Ehosctl.Activity,
    Ehosctl.Agents,
    Ehosctl.Installation,
    Ehosctl.Verify,
    Ehosctl.Versions
  ]

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
    # Read before parsing, since a command line Optimus refuses has no parse result: an error
    # is JSON when `--json` was asked for as a flag, before any `--`.
    json? = "--json" in Enum.take_while(argv, &(&1 != "--"))

    case Optimus.parse(optimus, normalize(argv, optimus)) do
      {:ok, [name | path], parsed} ->
        command = Enum.find(commands, &(&1.name() == name))

        if path == [] and Keyword.has_key?(command.spec(), :subcommands) and
             not optional?(command, :runs_bare?) do
          say(help(optimus, commands, [name]))
        else
          command |> run(path, parsed, opts) |> finish(json?)
        end

      {:ok, _parsed} ->
        say(help(optimus, commands, []))

      :version ->
        say(version_text())

      :help ->
        say(help(optimus, commands, []))

      {:help, path} ->
        say(help(optimus, commands, path))

      {:error, errors} ->
        invalid(unknown_command(argv, optimus) || errors, "ehosctl --help", json?)

      {:error, path, errors} ->
        {_, [_ | names]} = Optimus.fetch_subcommand(optimus, path)
        invalid(errors, "ehosctl help #{Enum.join(names, " ")}", json?)
    end
  end

  # A governed command is handed the installation it talks to, and does not run without one
  # (T-07), unless it chooses one itself.
  defp run(command, path, parsed, opts) do
    if command.plane() == :governed and not chooses_installation?(command) do
      dir = Keyword.get_lazy(opts, :config_dir, &Config.dir/0)

      with {:ok, config} <- Config.read(dir),
           {:ok, installation} <- Config.select(config, parsed.options[:installation]) do
        command.call(path, parsed, Keyword.put(opts, :installation, installation))
      end
    else
      command.call(path, parsed, opts)
    end
  end

  defp chooses_installation?(command), do: optional?(command, :chooses_installation?)

  # An optional callback of `Ehosctl.Command`, `false` when the command does not define it.
  defp optional?(command, callback) do
    Code.ensure_loaded!(command)
    function_exported?(command, callback, 0) and apply(command, callback, [])
  end

  # Optimus reads `--help` and `help <command>` only as the whole command line, so
  # `<command…> --help` and `-h`, as people type them, are turned into those first. Only the
  # leading words that name a command or subcommand are kept: `init shop --help` is the help of
  # `init`. After `--`, a `-h` is an argument like any other.
  defp normalize(argv, _optimus) when argv in [["-h"], ["help"]], do: ["--help"]

  defp normalize(argv, optimus) do
    case Enum.split(argv, -1) do
      {[_ | _] = words, [flag]} when flag in ["--help", "-h"] ->
        words = Enum.drop_while(words, &(&1 == "help"))
        path = command_path(optimus, words)

        cond do
          "--" in words -> argv
          words == [] -> ["--help"]
          # A word after the commands that names none of a command's subcommands: Optimus
          # says it is not one, rather than printing the help of the command before it.
          (next = unknown_after(optimus, words, path)) != nil -> ["help" | path ++ [next]]
          true -> ["help" | path]
        end

      _ ->
        argv
    end
  end

  # The word after `path` in `words`, when it is not a flag and `path` names no command, or a
  # command whose subcommands it is not one of.
  defp unknown_after(optimus, words, path) do
    case Enum.drop(words, length(path)) do
      [next | _] ->
        if not String.starts_with?(next, "-") and
             (path == [] or subcommands_at(optimus, path) != []),
           do: next

      [] ->
        nil
    end
  end

  defp subcommands_at(optimus, []), do: optimus.subcommands || []

  defp subcommands_at(optimus, [word | rest]) do
    optimus.subcommands |> Enum.find(&(&1.name == word)) |> subcommands_at(rest)
  end

  defp command_path(optimus, [word | rest]) do
    case Enum.find(optimus.subcommands || [], &(&1.name == word)) do
      nil -> []
      sub -> [word | command_path(sub, rest)]
    end
  end

  defp command_path(_optimus, []), do: []

  # At the top, Optimus reads a word it does not know as an argument nobody declared, or, after
  # `help`, as an invalid subcommand; a person typed it as a command.
  defp unknown_command(argv, optimus) do
    words = Enum.drop_while(argv, &(&1 == "help"))
    path = command_path(optimus, words)

    case unknown_after(optimus, words, path) do
      nil -> nil
      word -> ["unknown command #{inspect(Enum.join(path ++ [word], " "))}"]
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
  governed command that runs, a subcommand when it has them, takes `--installation` (T-07).
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

          spec =
            if command.plane() == :governed,
              do: governed(spec, optional?(command, :runs_bare?)),
              else: spec

          {command.name(), spec}
        end)
    )
  end

  defp governed(spec, bare? \\ false) do
    option = [
      installation: [
        long: "--installation",
        value_name: "NAME",
        help: "The installation to talk to, instead of EHOSCTL_INSTALLATION or the current one."
      ]
    ]

    # Only on the command that runs: Optimus stops looking for subcommands at the first option,
    # so `--installation` before a subcommand's name would hide it. A command that also runs
    # bare takes it itself as well.
    case spec[:subcommands] do
      nil ->
        Keyword.update(spec, :options, option, &(&1 ++ option))

      subs ->
        spec = if bare?, do: Keyword.update(spec, :options, option, &(&1 ++ option)), else: spec
        Keyword.put(spec, :subcommands, Enum.map(subs, fn {k, v} -> {k, governed(v)} end))
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

  # The version on the first line, which CI compares with the tag; for a build between releases,
  # the commit it was built from on a second (eh-os D-91).
  defp version_text do
    version = Ehosctl.version()

    case {Version.parse(version), Ehosctl.commit()} do
      {{:ok, %Version{pre: [_ | _]}}, commit} when is_binary(commit) ->
        "ehosctl #{version}\ncommit #{commit}"

      _release ->
        "ehosctl #{version}"
    end
  end

  defp say(text) do
    IO.puts(text)
    0
  end
end
