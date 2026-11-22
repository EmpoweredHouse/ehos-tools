defmodule Ehosctl.Init do
  @moduledoc """
  `ehosctl init <name>`: a new application, generated from the pinned template.

  After this the directory is ready to use: Hex is present for the toolchain it pins, and
  `.tool-versions` is trusted, so `cd <name>` puts the pinned Erlang and Elixir on the path,
  unless another version manager's shims (asdf's) come before mise's there: see
  [With asdf](README.md#with-asdf).

  The steps are plain commands, built first and then run, so what `init` would do is
  a value a test can read. Each step is said on stderr, after `==>`, and what its program prints
  follows it there, indented, as it prints it (`Ehosctl.Output.printed/2`). stdout holds the
  outcome alone: the directory, the toolchain and the name in EHOS, and the commands to run next.
  A step that fails gives what is left to do, as commands to paste. Everything runs under the Erlang and Elixir the template
  pins, through `mise exec`, which installs them on first use. The Mix archives
  (`hex`, `phx_new`, `igniter_new`) go to a directory of this `ehosctl` version rather
  than the developer's own `~/.mix`, so generating a project changes nothing the
  developer installed themselves.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Failure
  alias Ehosctl.Mise
  alias Ehosctl.Output
  alias Ehosctl.Template
  alias EhosPlatform.Shell

  # The name is the OTP application's, which allows no dash, so a dash is written as an
  # underscore. The template names the application in EHOS with dashes instead, since EHOS
  # makes it a DNS label: `my_shop` is `my-shop` there. It ends with a letter or a digit,
  # as a DNS label does.
  @name ~r/\A[a-z]([a-z0-9_]*[a-z0-9])?\z/

  @first_message "Generate the application with ehosctl init"

  @typedoc """
  A command `init` runs: `say`, the step a person reads, and `on_failure`, what to add to the
  failure: what is left behind, and what to do about it.
  """
  @type step :: %{
          cmd: String.t(),
          args: [String.t()],
          env: [{String.t(), String.t()}],
          say: String.t(),
          skip_if: nil | {:archive, Path.t(), String.t()},
          on_failure: nil | Failure.t()
        }

  # The rules for a name, said once for both helps: `ehosctl init --help`, which Optimus prints
  # from `spec/0`, and `run/2`'s own, for a caller that hands it `--help`.
  @name_format "The name has lowercase letters, digits and underscores. It starts with a " <>
                 "letter and ends with a letter or a digit."

  @name_rules @name_format <>
                " ehosctl writes a dash as an underscore. In EHOS, the application has dashes " <>
                "instead: `my_shop` is `my-shop` there."

  @usage_text "Create a new EHOS application in the directory NAME. NAME is the name of the " <>
                "OTP application. " <> @name_rules

  # Wrapped here at 88 columns, as Optimus wraps the help it prints from `spec/0`.
  @usage "Usage: ehosctl init NAME\n\n" <>
           (@usage_text
            |> String.split(" ")
            |> Enum.reduce([], fn
              word, [line | lines] when byte_size(line) + byte_size(word) < 88 ->
                [line <> " " <> word | lines]

              word, lines ->
                [word | lines]
            end)
            |> Enum.reverse()
            |> Enum.join("\n")) <> "\n"

  @impl Ehosctl.Command
  def name, do: :init

  @impl Ehosctl.Command
  def plane, do: :local

  @impl Ehosctl.Command
  def group, do: :start

  @impl Ehosctl.Command
  def summary, do: "Create an application, or the files of a utility service."

  @impl Ehosctl.Command
  def spec do
    [
      about:
        "Create a new EHOS application in the directory NAME. With --service, write the files " <>
          "of the utility service NAME in this directory.",
      args: [
        name: [
          value_name: "NAME",
          required: true,
          help:
            "The name of the OTP application. " <>
              @name_rules <>
              " With --service, the name of the utility service in EHOS: lowercase letters, " <>
              "digits and dashes."
        ]
      ],
      flags: [
        service: [
          long: "--service",
          help:
            "Write ehos.yaml and the pipeline of a utility service, a program with no " <>
              "contract and no Elixir project, in this directory. ehosctl keeps each file " <>
              "that exists."
        ]
      ],
      options: Ehosctl.InitService.options()
    ]
  end

  @impl Ehosctl.Command
  # Past `run/2`'s own help: the name Optimus read is a name, `-h` after `--` included.
  def call([], %Optimus.ParseResult{args: %{name: name}, flags: %{service: true}} = parsed, opts),
    do: Ehosctl.InitService.create(name, parsed.options, opts)

  def call([], %Optimus.ParseResult{args: %{name: name}, options: options}, opts) do
    case for({option, value} when value != nil <- options, do: option) do
      [] ->
        create([name], opts)

      given ->
        {:error, :invalid,
         "#{Enum.map_join(Enum.sort(given), " and ", &"--#{String.replace(to_string(&1), "_", "-")}")} " <>
           for_a_service(length(given))}
    end
  end

  defp for_a_service(1), do: "is for a utility service. Give --service as well, or leave it out."

  defp for_a_service(_several),
    do: "are for a utility service. Give --service as well, or leave them out."

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

  def run(argv, opts), do: create(argv, opts)

  defp create(argv, opts) do
    with {:ok, name} <- parse(argv),
         :ok <- say_renamed(argv, name),
         :ok <- refuse_existing(name),
         {:ok, dep} <- failed(Template.install_dep()),
         {:ok, mise} <- failed(Mise.find()),
         {:ok, git} <- find_git(),
         0 <-
           name
           |> steps(mise, Keyword.get_lazy(opts, :archives, &archives_dir/0), git: git, dep: dep)
           |> Enum.reject(&satisfied?/1)
           |> run_steps() do
      Output.result(%{text: created(name), json: nil}, false)
    else
      {:error, kind, message} -> Output.error(kind, message, false)
      status -> status
    end
  end

  defp failed({:ok, value}), do: {:ok, value}
  defp failed({:error, message}), do: {:error, :failed, message}

  # The name in EHOS has dashes where the OTP application has underscores.
  defp created(name) do
    Output.lines([
      Output.outcome(:done, "ehosctl created the application #{name} in #{name}/."),
      Output.values([
        {"Directory", name <> "/"},
        {"Erlang", Template.erlang()},
        {"Elixir", Template.elixir()},
        {"Name in EHOS", String.replace(name, "_", "-")}
      ]),
      "",
      Output.next(["cd " <> Shell.word(name), "mix setup"])
    ])
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
      Failure.new(" #{name}/ can be half generated.",
        advice: "Remove #{name}/, then run the command again:",
        to_do: ["ehosctl init " <> Shell.word(name)]
      )

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
          "Installing Erlang #{Template.erlang()} and Elixir #{Template.elixir()} with mise",
          Failure.new(" mise could not install #{Enum.join(tools(), " and ")}.",
            advice:
              "If mise has no precompiled Erlang, it builds Erlang from source, which needs " <>
                "the tools on https://mise.jdx.dev/lang/erlang.html."
          )
        )
        | env: [Mise.tools_first()]
      },
      step(
        mise,
        ["mix", "local.hex", "--force"],
        env,
        "Installing Hex for the generators",
        {:archive, archives, "hex-"}
      ),
      step(
        mise,
        ["mix", "archive.install", "hex", "phx_new", Template.phx_new(), "--force"],
        env,
        "Installing the generator phx_new #{Template.phx_new()}",
        {:archive, archives, "phx_new-#{Template.phx_new()}"}
      ),
      step(
        mise,
        ["mix", "archive.install", "hex", "igniter_new", Template.igniter_new(), "--force"],
        env,
        "Installing the generator igniter_new #{Template.igniter_new()}",
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
        "Generating the Phoenix project #{name}",
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
        "Installing ehos_app in #{name}/",
        left_behind
      ),
      # The generated project is used with the developer's own Mix, not the archives
      # above, and needs Hex before its first `mix` command. mise gives each Elixir
      # install its own Mix home, so this touches nothing outside that install.
      step(
        mise,
        ["mix", "local.hex", "--force", "--if-missing"],
        [],
        "Installing Hex for Elixir #{Template.elixir()}",
        nil,
        by_hand(
          " ehosctl generated #{name}/, but Hex is not installed for its Elixir.",
          [trust(name), "cd " <> Shell.word(name), "mix local.hex", "mix format"]
        )
      ),
      # mise refuses to read a config file nobody has trusted. This one was written a
      # moment ago by the template, not taken from someone else's repository.
      plain_step(
        mise,
        ["trust", Path.join(name, ".tool-versions")],
        "Trusting #{name}/.tool-versions with mise",
        by_hand(
          " ehosctl generated #{name}/, but mise does not trust it yet.",
          [trust(name), "cd " <> Shell.word(name), "mix format"]
        )
      ),
      # `phx.new` writes a test whose line holds the module's name, so a module name of 11
      # characters or more, `OfficeClient` among them, leaves it unformatted, and the first run
      # of CI fails its `mix format` gate (ehos-tools#574). Formatted here, the first commit
      # passes it.
      step_in(
        name,
        mise,
        ["mix", "format"],
        [],
        "Formatting #{name}/",
        by_hand(
          " ehosctl generated #{name}/, but mix format failed in it.",
          ["cd " <> Shell.word(name), "mix format"],
          "Correct what mix format printed above. Then finish the setup by hand:"
        )
      )
    ] ++ first_commit(name, git)
  end

  # What `igniter.new` would have committed, had it run last. The first branch is `main`, not
  # `init.defaultBranch`, whose default is still `master` in the git most Linux distributions
  # ship, while the generated CI publishes from `main` alone (ehos-tools#190). `phx.new` has
  # already run `git init` (phx_new 1.8 always does, outside a repository, and has no option
  # against it), so `git init --initial-branch=main` here would be a re-initialisation, which
  # ignores the branch: the unborn `HEAD` is pointed at `main` instead, which any git can do.
  defp first_commit(name, git) do
    left_uncommitted =
      by_hand(
        " ehosctl generated #{name}/, but did not commit it.",
        ["cd " <> Shell.word(name)],
        "Commit it by hand:"
      )

    for args <- [
          ["init", "--quiet"],
          ["symbolic-ref", "HEAD", "refs/heads/main"],
          ["add", "--all"],
          ["commit", "--quiet", "--message", @first_message]
        ] do
      %{
        cmd: git,
        args: ["-C", name | args],
        env: [],
        say: "Committing #{name}/ on the branch main",
        skip_if: nil,
        on_failure: left_uncommitted
      }
    end
  end

  # What a project left before its first commit still needs once its toolchain works: `before`,
  # then committed in a repository of its own, on `main` (ehos-tools#190). `git init` stays:
  # phx.new skips it inside another repository, whose HEAD the rest would then move.
  defp by_hand(said, before, advice \\ "Finish the setup by hand:") do
    Failure.new(said,
      advice: advice,
      to_do:
        before ++
          [
            "git init",
            "git symbolic-ref HEAD refs/heads/main",
            "git add -A",
            "git commit -m " <> Shell.word(@first_message)
          ]
    )
  end

  defp trust(name), do: "mise trust " <> Shell.word(Path.join(name, ".tool-versions"))

  defp tools, do: ["erlang@#{Template.erlang()}", "elixir@#{Template.elixir()}"]

  # A Mix command, under the pinned toolchain, put ahead of any other version manager's on the
  # `PATH` (`Ehosctl.Mise.tools_first/0`): under asdf's `elixir`, the project would be generated,
  # and its `.tool-versions` written, under that one.
  defp step(mise, command, env, say, skip_if, on_failure \\ nil) do
    args = ["exec" | tools()] ++ ["--" | command]
    env = env ++ [Mise.tools_first()]
    %{cmd: mise, args: args, env: env, say: say, skip_if: skip_if, on_failure: on_failure}
  end

  # A Mix command, under the pinned toolchain, in the project `dir`.
  defp step_in(dir, mise, command, env, say, on_failure) do
    step(mise, command, env, say, nil, on_failure) |> Map.update!(:args, &["-C", dir | &1])
  end

  # A command of mise's own.
  defp plain_step(mise, args, say, on_failure) do
    %{cmd: mise, args: args, env: [], say: say, skip_if: nil, on_failure: on_failure}
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

  # Each step is said once, however many commands it runs, as the commit's four are.
  defp run_steps(steps) do
    steps
    |> Enum.reduce_while({0, nil}, fn step, {0, said} ->
      if step.say != said, do: Output.progress(step.say)

      case run_step(step) do
        0 -> {:cont, {0, step.say}}
        status -> {:halt, {say_failed(step, status), step.say}}
      end
    end)
    |> elem(0)
  end

  defp run_step(%{cmd: cmd, args: args, env: env}) do
    {status, printing} =
      Ehosctl.Runner.current().streamed(cmd, args, env, Output.printing(), &Output.printed/2)

    Output.printed_end(printing)
    status
  end

  # The step's own exit status is `init`'s (`Ehosctl.Output`'s exception), whatever the kind.
  defp say_failed(%{cmd: cmd} = step, status) do
    said = "#{step.say} failed: #{Path.basename(cmd)} exited with #{status}."
    failure = step.on_failure || Failure.new("")
    Output.error(:failed, %{failure | said: said <> failure.said}, false)
    status
  end

  defp parse([given]) do
    name = String.replace(given, "-", "_")

    if name =~ @name do
      {:ok, name}
    else
      {:error, :invalid,
       "#{inspect(given)} is not a valid name for an application. " <> @name_format}
    end
  end

  defp parse(_argv), do: {:error, :invalid, "Give one argument: the name of the application."}

  defp say_renamed([name], name), do: :ok

  defp say_renamed([given], name) do
    Output.warn(
      "ehosctl generates #{given} as #{name}, in the directory #{name}/.",
      "The name of an OTP application has no dash. EHOS names the application #{given}."
    )
  end

  defp refuse_existing(name) do
    if File.exists?(name),
      do: {:error, :failed, "#{name} already exists. Give another name, or remove #{name}."},
      else: :ok
  end

  defp find_git do
    case Ehosctl.OS.current().find_executable("git") do
      nil ->
        {:error, :failed,
         "git: ehosctl cannot find it. ehosctl needs git to fetch the application template and to " <>
           "commit the new project. Install git, and run the command again."}

      path ->
        {:ok, path}
    end
  end

  defp archives_dir do
    Path.join([:filename.basedir(:user_cache, "ehosctl"), Ehosctl.version(), "mix_archives"])
  end
end
