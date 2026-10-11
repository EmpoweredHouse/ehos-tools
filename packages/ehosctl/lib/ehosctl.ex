defmodule Ehosctl do
  @moduledoc """
  The terminal's way into EHOS.

  Its first command, `ehosctl init`, needs no EHOS at all: it creates an application
  from the template. The commands that talk to EHOS (`login`, `verify`, calling a
  declared command) follow as EHOS grows the API they go through.
  """

  # The commit this build is made from (eh-os D-91: a build between releases says what it was
  # built from): CI's `GITHUB_SHA`, else the checkout's `HEAD`, else none. A build never fails for
  # want of it. On a pull request `GITHUB_SHA` is GitHub's merge commit, not the branch's head;
  # releases are built from a tag or `main`, where it is the commit itself. Read when this module
  # is compiled, so a build that is not forced keeps the commit it was first compiled at.
  @commit (case System.get_env("GITHUB_SHA") do
             sha when is_binary(sha) and sha != "" ->
               sha

             _none ->
               try do
                 case System.cmd("git", ["rev-parse", "HEAD"],
                        cd: __DIR__,
                        stderr_to_stdout: true
                      ) do
                   {sha, 0} -> String.trim(sha)
                   _failed -> nil
                 end
               rescue
                 _no_git -> nil
               end
           end)
          |> then(&if(is_binary(&1) and &1 =~ ~r/\A[0-9a-f]{40}\z/, do: &1))

  @doc "The version this binary was built as."
  @spec version() :: String.t()
  def version, do: Application.spec(:ehosctl, :vsn) |> to_string()

  @doc """
  The commit this binary was built from, 40 hexadecimal digits, or `nil` when the build was not
  told it and had no git checkout to ask.
  """
  @spec commit() :: String.t() | nil
  def commit, do: @commit
end
