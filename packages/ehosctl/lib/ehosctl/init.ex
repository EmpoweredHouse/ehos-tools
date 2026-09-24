defmodule Ehosctl.Init do
  @moduledoc """
  `ehosctl init <name>`: a new application, generated from the pinned template.

  After this the directory is ready to use: Hex is present for the toolchain it pins, and
  `.tool-versions` is trusted, so `cd <name>` puts the pinned Erlang and Elixir on the path.

  The steps are plain commands, built first and then run, so what `init` would do is
  a value a test can read. Everything runs under the Erlang and Elixir the template
  pins, through `mise exec`, which installs them on first use. The Mix archives
  (`hex`, `phx_new`, `igniter_new`) go to a directory of this `ehosctl` version rather
  than the developer's own `~/.mix`, so generating a project changes nothing the
  developer installed themselves.
  """

  alias Ehosctl.Template

  @name ~r/\A[a-z][a-z0-9_]*\z/

  @type step :: %{
          cmd: String.t(),
          args: [String.t()],
          env: [{String.t(), String.t()}],
          skip_if: nil | {:archive, Path.t(), String.t()},
          on_failure: nil | String.t()
        }

  @usage """
  Usage: ehosctl init <name>

  Creates a new EHOS application in the directory <name>. The name is the OTP
  application name: lowercase letters, digits and underscores, starting with a letter.
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
         :ok <- refuse_existing(name),
         {:ok, mise} <- find_mise(opts) do
      name
      |> steps(mise, Keyword.get_lazy(opts, :archives, &archives_dir/0))
      |> Enum.reject(&satisfied?/1)
      |> run_steps(runner)
    else
      {:error, message} ->
        IO.puts(:stderr, "ehosctl init: " <> message)
        1
    end
  end

  @doc "The commands `init` runs, in order."
  @spec steps(String.t(), String.t(), Path.t()) :: [step]
  def steps(name, mise, archives) do
    env = [{"MIX_ARCHIVES", archives}]

    # Once generation has started the directory exists, and a second `init` refuses it,
    # so a failure from here on says what is left behind. After generation the project
    # is complete, and a failure says which setup step to finish by hand.
    left_behind =
      "`#{name}/` may be left half generated. " <>
        "Remove it before running `ehosctl init #{name}` again."

    [
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
          "--install",
          Template.install_spec(),
          "--example",
          "--yes",
          "--no-installer-version-check"
        ],
        env,
        nil,
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
      %{
        cmd: mise,
        args: ["trust", Path.join(name, ".tool-versions")],
        env: [],
        skip_if: nil,
        on_failure:
          "`#{name}/` was generated, but mise does not trust it yet. " <>
            "Run `mise trust #{name}/.tool-versions`."
      }
    ]
  end

  defp step(mise, command, env, skip_if, on_failure \\ nil) do
    toolchain = ["exec", "erlang@#{Template.erlang()}", "elixir@#{Template.elixir()}", "--"]
    %{cmd: mise, args: toolchain ++ command, env: env, skip_if: skip_if, on_failure: on_failure}
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
          IO.puts(:stderr, "ehosctl init: `#{Enum.join(args, " ")}` exited with #{status}")
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

  defp parse([name]) do
    if name =~ @name do
      {:ok, name}
    else
      {:error,
       "#{inspect(name)} is not a valid application name: " <>
         "lowercase letters, digits and underscores, starting with a letter"}
    end
  end

  defp parse(_argv), do: {:error, "expected one argument, the application name"}

  defp refuse_existing(name) do
    if File.exists?(name), do: {:error, "#{name} already exists"}, else: :ok
  end

  defp find_mise(opts) do
    case Keyword.get_lazy(opts, :mise, fn -> System.find_executable("mise") end) do
      nil -> {:error, "mise is needed to install Erlang and Elixir: brew install mise"}
      path -> {:ok, path}
    end
  end

  defp archives_dir do
    Path.join([:filename.basedir(:user_cache, "ehosctl"), Ehosctl.version(), "mix_archives"])
  end
end
