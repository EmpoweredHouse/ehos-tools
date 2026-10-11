defmodule Ehosctl.Build do
  @moduledoc """
  The commit a build of `ehosctl` is made from (eh-os D-91: a build between releases says what
  it was built from), read when `Ehosctl` is compiled, and again by Mix before each compile, so a
  build that is not forced takes a new commit (the `__mix_recompile__?` function of `Ehosctl`).
  """

  @doc """
  CI's `GITHUB_SHA`, else the checkout's `HEAD`, else `nil`; only 40 hexadecimal digits are a
  commit. Never fails: without git or a checkout, there is none.

  On a pull request `GITHUB_SHA` is GitHub's merge commit, not the branch's head; releases are
  built from a tag or `main`, where it is the commit itself.
  """
  @spec commit(%{String.t() => String.t()}) :: String.t() | nil
  def commit(env \\ System.get_env()) do
    case env["GITHUB_SHA"] do
      sha when is_binary(sha) and sha != "" -> sha
      _none -> head()
    end
    |> then(&if(is_binary(&1) and &1 =~ ~r/\A[0-9a-f]{40}\z/, do: &1))
  end

  defp head do
    case System.cmd("git", ["rev-parse", "HEAD"], cd: __DIR__, stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _failed -> nil
    end
  rescue
    _no_git -> nil
  end
end
