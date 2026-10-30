defmodule EhosPlatform.Shell do
  @moduledoc """
  Words for a command a person pastes into a POSIX shell, as the commands the platform and
  `ehosctl` suggest are printed, and whether a text is safe to print in one (`printable?/1`).
  Nothing here runs a shell.
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

  @doc """
  Whether `text` is valid UTF-8 with no character a terminal acts on rather than shows: no control
  or format character and no line or paragraph separator, the rule `ehosctl` holds what it prints
  to (`Ehosctl.Output.printable?/1`).

      iex> EhosPlatform.Shell.printable?("/home/ada/.ssh/ehos_acme")
      true

      iex> EhosPlatform.Shell.printable?("/home/ada/.ssh/ehos\e[2J")
      false
  """
  @spec printable?(String.t()) :: boolean()
  def printable?(text),
    do: String.printable?(text) and not String.match?(text, ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u)
end
