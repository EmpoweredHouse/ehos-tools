defmodule EhosPlatform.Shell do
  @moduledoc """
  Words for a command a person pastes into a POSIX shell, as the commands the platform and
  `ehosctl` suggest are printed. Nothing here runs a shell.
  """

  @doc """
  `value` as one word of a POSIX shell: as it is when it is made of letters, digits and
  `@%+=:,./_-` alone and does not start with `=`, else in single quotes, a `'` within written as
  `'\\''`.

      iex> EhosPlatform.Shell.word("/home/ada/.ehos/trial/kubeconfig")
      "/home/ada/.ehos/trial/kubeconfig"

      iex> EhosPlatform.Shell.word("/Users/Jane O'Brien")
      ~S('/Users/Jane O'\\''Brien')

      iex> EhosPlatform.Shell.word("")
      "''"

  A word that starts with `=` is quoted too, as zsh would expand it to a program's path.

      iex> EhosPlatform.Shell.word("=ada")
      "'=ada'"
  """
  @spec word(String.t()) :: String.t()
  def word(value) do
    if value =~ ~r/\A[A-Za-z0-9@%+:,.\/_-][A-Za-z0-9@%+=:,.\/_-]*\z/,
      do: value,
      else: "'" <> String.replace(value, "'", ~S('\'')) <> "'"
  end

  @doc """
  `value` as an extended regular expression that matches it as it is, as `pkill -f` and
  `grep -E` read one: each of `\\.[]()*+?{}|^$` escaped with a backslash. A word for the shell
  still, through `word/1`.

      iex> EhosPlatform.Shell.pattern("/Users/jane+work/tunnel.sock")
      ~S(/Users/jane\\+work/tunnel\\.sock)
  """
  @spec pattern(String.t()) :: String.t()
  def pattern(value), do: String.replace(value, ~r/[\\.\[\]()*+?{}|^$]/, "\\\\\\0")
end
