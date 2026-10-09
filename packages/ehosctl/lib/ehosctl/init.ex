defmodule Ehosctl.Init do
  @moduledoc """
  `ehosctl init <name>`: a new application, generated from the pinned template.

  After this the directory is ready to use: Hex is present for the toolchain it pins, and
  `.tool-versions` is trusted, so `cd <name>` puts the pinned Erlang and Elixir on the path,
  unless another version manager's shims (asdf's) come before mise's there: see the root README of ehos-tools, "Getting started".

  The steps are plain commands, built first and then run, so what `init` would do is
  a value a test can read. Everything runs under the Erlang and Elixir the template
  pins, through `mise exec`, which installs them on first use. The Mix archives
  (`hex`, `phx_new`, `igniter_new`) go to a directory of this `ehosctl` version rather
  than the developer's own `~/.mix`, so generating a project changes nothing the
  developer installed themselves.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Template

  @tools_first {"MISE_ACTIVATE_AGGRESSIVE", "1"}

  # The name is the OTP application's, which allows no dash, so a dash is written as an
  # underscore. The template names the application in EHOS with dashes instead, since EHOS
  # makes it a DNS label: `my_shop` is `my-shop` there. It ends with a letter or a digit,
  # as a DNS label does.
  @name ~r/\A[a-z]([a-z0-9_]*[a-z0-9])?\z/

  @type step :: %{
          cmd: String.t(),
          args: [String.t()],
          env: [{String.t(), String.t()}],
          skip_if: nil | {:archive, Path.t(), String.t()},
          on_failure: nil | String.t()
        }

  # The rules for a name, said once for both helps: `ehosctl init --help`, which Optimus prints
  # from `spec/0`, and `run/2`'s own, for a caller that hands it `--help`.
  @name_rules "lowercase letters, digits and underscores, starting with a letter and ending " <>
                "with a letter or a digit. A dash is written as an underscore. In EHOS the " <>
                "application is named with dashes instead: `my_shop` is `my-shop` there."

  @usage """
  Usage: ehosctl init <name>

  Creates a new EHOS application in the directory <name>. The name is the OTP application's:
  #{@name_rules}
  """

  @impl Ehosctl.Command
  def name, do: :init

  @impl Ehosctl.Command
  def plane, do: :local

  @impl Ehosctl.Command
  def spec do
    [
      about: "Create a new EHOS application in the directory <name>.",
      args: [
        name: [
          value_name: "NAME",
          required: true,
          help: "The OTP application's name: " <> @name_rules
        ]
      ]
    ]
  end

  @impl Ehosctl.Command
  def call([], %Optimus.ParseResult{args: %{name: name}}, opts), do: run([name], opts)

  @doc """
  Creates the application `argv` names, and returns the exit code: the failing step's own
  when a step fails.
  """
  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run(argv, opts \\ [])

  def run([flag], _opts) when flag in ["--help", "-h"] do
    IO.puts(@usage)
    0
  end

  def run(argv, opts) do
    runner = Keyword.get(opts, :runner, &run_command/3)

    with {:ok, name} <- parse(argv),
         :ok <- say_renamed(argv, name),
         :ok <- refuse_existing(name),
         {:ok, dep} <- Template.install_dep(),
         {:ok, mise} <- find_mise(opts),
         {:ok, git} <- find_git(opts) do
      name
      |> steps(mise, Keyword.get_lazy(opts, :archives, &archives_dir/0), git: git, dep: dep)
      |> Enum.reject(&satisfied?/1)
      |> run_steps(runner)
    else
      {:error, message} ->
        IO.puts(:stderr, "ehosctl init: " <> message)
        1
    end
  end

  @doc """
  The commands `init` runs, in order. `opts` name git's executable (`:git`) and the
  `ehos_app` dependency to install (`:dep`, by default `Ehosctl.Template.install_dep/0`'s).
  """
  @spec steps(String.t(), String.t(), Path.t(), keyword()) :: [step]
  def steps(name, mise, archives, opts \\ []) do
    env = [{"MIX_ARCHIVES", archives}]
    git = Keyword.get(opts, :git, "git")
    dep = Keyword.get_lazy(opts, :dep, fn -> elem(Template.install_dep(), 1) end)

    # Once generation has started the directory exists, and a second `init` refuses it,
    # so a failure from here on says what is left behind. After generation the project
    # is complete, and a failure says which setup step to finish by hand.
    left_behind =
      "`#{name}/` may be left half generated. " <>
        "Remove it before running `ehosctl init #{name}` again."

    [
      # `mise exec erlang@X elixir@Y` cannot install a missing Elixir: it runs the new
      # Elixir's check without the Erlang named next to it on the path, and fails with
      # "exec: erl: not found" even when that Erlang is already installed (mise 2026.9).
      # `mise install` of both at once gives the Elixir install its Erlang, and does
      # nothing once both are there. `--quiet` drops mise's advice to `mise use` them,
      # which would pin them in the developer's global config.
      # Installing Elixir runs its `elixir --version`, which finds `erl` on the same `PATH`
      # as the Mix steps below: hence the same variable (`step/5`).
      %{
        plain_step(
          mise,
          ["install", "--quiet" | tools()],
          "mise could not install #{Enum.join(tools(), " and ")}. " <>
            "Where mise has no precompiled Erlang it builds it from source: " <>
            "https://mise.jdx.dev/lang/erlang.html"
        )
        | env: [@tools_first]
      },
      step(mise, ["mix", "local.hex", "--force"], env, {:archive, archives, "hex-"}),
      step(
        mise,
        ["mix", "archive.install", "hex", "phx_new", Template.phx_new(), "--force"],
        env,
        {:archive, archives, "phx_new-#{Template.phx_new()}"}
      ),
      step(
        mise,
        ["mix", "archive.install", "hex", "igniter_new", Template.igniter_new(), "--force"],
        env,
        {:archive, archives, "igniter_new-#{Template.igniter_new()}"}
      ),
      step(
        mise,
        [
          "mix",
          "igniter.new",
          name,
          "--with",
          "phx.new",
          "--with-args",
          Template.phx_new_args(),
          "--yes",
          "--no-installer-version-check",
          # The project's first commit comes last, once everything below has run.
          "--no-git"
        ],
        env,
        nil,
        left_behind
      ),
      # `ehos_app` is installed in the new project rather than through `igniter.new
      # --install`, whose spec has no `sparse:` (`Ehosctl.Template`). Its Hex is the
      # archives' one, as for `igniter.new`, since the project has none of its own yet.
      step_in(
        name,
        mise,
        ["mix", "run", "--no-start", "-e", Template.install_expression(dep)],
        env,
        left_behind
      ),
      # The generated project is used with the developer's own Mix, not the archives
      # above, and needs Hex before its first `mix` command. mise gives each Elixir
      # install its own Mix home, so this touches nothing outside that install.
      step(
        mise,
        ["mix", "local.hex", "--force", "--if-missing"],
        [],
        nil,
        "`#{name}/` was generated, but Hex is not installed for its Elixir. " <>
          "Run `mix local.hex` in it."
      ),
      # mise refuses to read a config file nobody has trusted. This one was written a
      # moment ago by the template, not taken from someone else's repository.
      plain_step(
        mise,
        ["trust", Path.join(name, ".tool-versions")],
        "`#{name}/` was generated, but mise does not trust it yet. " <>
          "Run `mise trust #{name}/.tool-versions`."
      )
    ] ++ first_commit(name, git)
  end

  # What `igniter.new` would have committed, had it run last.
  defp first_commit(name, git) do
    left_uncommitted =
      "`#{name}/` was generated, but not committed. " <>
        "Commit it in `#{name}/` with `git init`, `git add -A` and `git commit`."

    for args <- [
          ["init", "--quiet"],
          ["add", "--all"],
          ["commit", "--quiet", "--message", "Generate the application with ehosctl init"]
        ] do
      %{cmd: git, args: ["-C", name | args], env: [], skip_if: nil, on_failure: left_uncommitted}
    end
  end

  defp tools, do: ["erlang@#{Template.erlang()}", "elixir@#{Template.elixir()}"]

  # A Mix command, under the pinned toolchain. `mix` is `#!/usr/bin/env elixir`, so the
  # pinned Elixir has to come first on the `PATH`. When mise's shims are on it, `mise exec`
  # puts the tools' directories just before them, after any other version manager's shims
  # earlier on the `PATH` (asdf's), whose `elixir` picks its own version: the project
  # would be generated, and its `.tool-versions` written, under that one.
  # `MISE_ACTIVATE_AGGRESSIVE` puts them at the front instead. mise documents it for
  # `mise activate`; `mise exec` builds its `PATH` with the same code (`src/path_env.rs`),
  # which is what this relies on, checked with mise 2026.9.12.
  defp step(mise, command, env, skip_if, on_failure \\ nil) do
    args = ["exec" | tools()] ++ ["--" | command]
    env = env ++ [@tools_first]
    %{cmd: mise, args: args, env: env, skip_if: skip_if, on_failure: on_failure}
  end

  # A Mix command, under the pinned toolchain, in the project `dir`.
  defp step_in(dir, mise, command, env, on_failure) do
    step(mise, command, env, nil, on_failure) |> Map.update!(:args, &["-C", dir | &1])
  end

  # A command of mise's own.
  defp plain_step(mise, args, on_failure) do
    %{cmd: mise, args: args, env: [], skip_if: nil, on_failure: on_failure}
  end

  # `mix archive.install` unpacks into `<dir>/<name>-<vsn>/<name>-<vsn>/ebin`. Checking
  # for `ebin` rather than the directory alone keeps an install that was interrupted
  # half way from being taken for a finished one forever.
  defp satisfied?(%{skip_if: {:archive, dir, prefix}}) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.any?(entries, fn entry ->
          String.starts_with?(entry, prefix) and File.dir?(Path.join([dir, entry, entry, "ebin"]))
        end)

      {:error, _} ->
        false
    end
  end

  defp satisfied?(_step), do: false

  defp run_steps(steps, runner) do
    Enum.reduce_while(steps, 0, fn %{cmd: cmd, args: args, env: env} = step, 0 ->
      case runner.(cmd, args, env) do
        0 ->
          {:cont, 0}

        status ->
          command = Enum.join([Path.basename(cmd) | args], " ")
          IO.puts(:stderr, "ehosctl init: `#{command}` exited with #{status}")
          if step.on_failure, do: IO.puts(:stderr, "ehosctl init: " <> step.on_failure)
          {:halt, status}
      end
    end)
  end

  # `System.cmd/3` gives the command a pipe for stdin that nobody writes to, so a step
  # that asks a question would wait forever, and it can only merge stderr into stdout.
  # A port with `:nouse_stdio` talks to the command over other descriptors and leaves it
  # the terminal's stdin, stdout and stderr: prompts can be answered, and errors stay on
  # stderr.
  defp run_command(cmd, args, env) do
    env =
      Enum.map(env, fn {name, value} -> {String.to_charlist(name), String.to_charlist(value)} end)

    port = Port.open({:spawn_executable, cmd}, [:nouse_stdio, :exit_status, args: args, env: env])

    receive do
      {^port, {:exit_status, status}} -> status
    end
  end

  defp parse([given]) do
    name = String.replace(given, "-", "_")

    if name =~ @name do
      {:ok, name}
    else
      {:error,
       "#{inspect(given)} is not a valid application name: lowercase letters, digits and " <>
         "underscores, starting with a letter and ending with a letter or a digit"}
    end
  end

  defp parse(_argv), do: {:error, "expected one argument, the application name"}

  defp say_renamed([name], name), do: :ok

  defp say_renamed([given], name) do
    IO.puts(
      "ehosctl init: an OTP application's name has no dash, so #{given} is generated as " <>
        "#{name}, in the directory #{name}/. EHOS names it #{given}."
    )
  end

  defp refuse_existing(name) do
    if File.exists?(name), do: {:error, "#{name} already exists"}, else: :ok
  end

  defp find_mise(opts) do
    case Keyword.get_lazy(opts, :mise, fn -> System.find_executable("mise") end) do
      nil ->
        {:error,
         "mise is needed to install Erlang and Elixir: https://mise.jdx.dev/installing-mise.html"}

      path ->
        {:ok, path}
    end
  end

  defp find_git(opts) do
    case Keyword.get_lazy(opts, :git, fn -> System.find_executable("git") end) do
      nil -> {:error, "git is needed to fetch the template and commit the new project"}
      path -> {:ok, path}
    end
  end

  defp archives_dir do
    Path.join([:filename.basedir(:user_cache, "ehosctl"), Ehosctl.version(), "mix_archives"])
  end
end
