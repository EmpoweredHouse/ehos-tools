defmodule Ehosctl.Mise do
  @moduledoc """
  Running a command under a pinned Erlang and Elixir through mise, with the terminal's own input
  and output (`c:Ehosctl.Runner.interactive/3`), for `ehosctl init`, which creates an application
  under `ehosctl`'s pins, and `ehosctl verify`, which checks one under its own.
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

  @doc "The `mise` executable on the `PATH`, or why there is none."
  @spec find() :: {:ok, Path.t()} | {:error, String.t()}
  def find do
    case Ehosctl.OS.current().find_executable("mise") do
      nil ->
        {:error,
         "mise: ehosctl cannot find it. ehosctl needs mise to run Erlang and Elixir at the pinned " <>
           "versions. Install mise: https://mise.jdx.dev/installing-mise.html"}

      path ->
        {:ok, path}
    end
  end
end
