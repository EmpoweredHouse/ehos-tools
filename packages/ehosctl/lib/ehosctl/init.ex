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
          skip_if: nil | {:archive, Path.t(), String.t()}
        }

  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run(argv, opts \\ []) do
    runner = Keyword.get(opts, :runner, &System.cmd/3)

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
        nil
      ),
      # The generated project is used with the developer's own Mix, not the archives
      # above, and needs Hex before its first `mix` command. mise gives each Elixir
      # install its own Mix home, so this touches nothing outside that install.
      step(mise, ["mix", "local.hex", "--force", "--if-missing"], [], nil),
      # mise refuses to read a config file nobody has trusted. This one was written a
      # moment ago by the template, not taken from someone else's repository.
      %{cmd: mise, args: ["trust", Path.join(name, ".tool-versions")], env: [], skip_if: nil}
    ]
  end

  defp step(mise, command, env, skip_if) do
    toolchain = ["exec", "erlang@#{Template.erlang()}", "elixir@#{Template.elixir()}", "--"]
    %{cmd: mise, args: toolchain ++ command, env: env, skip_if: skip_if}
  end

  defp satisfied?(%{skip_if: {:archive, dir, prefix}}) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.any?(entries, &String.starts_with?(&1, prefix))
      {:error, _} -> false
    end
  end

  defp satisfied?(_step), do: false

  defp run_steps(steps, runner) do
    Enum.reduce_while(steps, 0, fn %{cmd: cmd, args: args, env: env}, 0 ->
      case runner.(cmd, args, env: env, into: IO.stream(:stdio, :line), stderr_to_stdout: true) do
        {_, 0} ->
          {:cont, 0}

        {_, status} ->
          IO.puts(:stderr, "ehosctl init: `#{Enum.join(args, " ")}` exited with #{status}")
          {:halt, status}
      end
    end)
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
