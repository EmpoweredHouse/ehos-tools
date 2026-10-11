defmodule Ehosctl.Mise do
  @moduledoc """
  Running a command under a pinned Erlang and Elixir through mise, with the terminal's own input
  and output, for `ehosctl init`, which creates an application under `ehosctl`'s pins, and
  `ehosctl verify`, which checks one under its own.
  """

  # `mix` is `#!/usr/bin/env elixir`, so the pinned Elixir has to come first on the `PATH`. When
  # mise's shims are on it, `mise exec` puts the tools' directories just before them, after any
  # other version manager's shims earlier on the `PATH` (asdf's), whose `elixir` picks its own
  # version. `MISE_ACTIVATE_AGGRESSIVE` puts them at the front instead. mise documents it for
  # `mise activate`; `mise exec` builds its `PATH` with the same code (`src/path_env.rs`), which is
  # what this relies on, checked with mise 2026.9.12.
  @tools_first {"MISE_ACTIVATE_AGGRESSIVE", "1"}

  @doc "The environment variable that puts the pinned tools ahead of any other on the `PATH`."
  @spec tools_first() :: {String.t(), String.t()}
  def tools_first, do: @tools_first

  @doc "The `mise` executable, `opts[:mise]` when a test gives one, or why there is none."
  @spec find(keyword()) :: {:ok, Path.t()} | {:error, String.t()}
  def find(opts) do
    case Keyword.get_lazy(opts, :mise, fn -> System.find_executable("mise") end) do
      nil ->
        {:error,
         "mise is needed to install Erlang and Elixir: https://mise.jdx.dev/installing-mise.html"}

      path ->
        {:ok, path}
    end
  end

  @doc """
  Runs `cmd` with `args` and `env`, and returns its exit status.

  `System.cmd/3` gives the command a pipe for stdin that nobody writes to, so a command that asks
  a question would wait forever, and it can only merge stderr into stdout. A port with
  `:nouse_stdio` talks to the command over other descriptors and leaves it the terminal's stdin,
  stdout and stderr: prompts can be answered, and errors stay on stderr.
  """
  @spec run(String.t(), [String.t()], [{String.t(), String.t()}]) :: non_neg_integer()
  def run(cmd, args, env) do
    env =
      Enum.map(env, fn {name, value} -> {String.to_charlist(name), String.to_charlist(value)} end)

    port = Port.open({:spawn_executable, cmd}, [:nouse_stdio, :exit_status, args: args, env: env])

    receive do
      {^port, {:exit_status, status}} -> status
    end
  end
end
