defmodule EhosPlatform.Shell do
  @moduledoc """
  Words for a command a person pastes into a POSIX shell, as the commands the platform and
  `ehosctl` suggest are printed, and whether a text is safe to print in one (`printable?/1`).
  Nothing here runs a shell.
  """

  @doc """
  `value` as one word of a POSIX shell: as it is when it is made of letters, digits and
  `@%+=:,./_-` alone and does not start with `=` or `-`, else in single quotes, a `'` within
  written as `'\\''`.

      iex> EhosPlatform.Shell.word("/home/ada/.ehos/trial/kubeconfig")
      "/home/ada/.ehos/trial/kubeconfig"

      iex> EhosPlatform.Shell.word("/Users/Jane O'Brien")
      ~S('/Users/Jane O'\\''Brien')

      iex> EhosPlatform.Shell.word("")
      "''"

  A word that starts with `=` is quoted too, as zsh would expand it to a program's path.

      iex> EhosPlatform.Shell.word("=ada")
      "'=ada'"

  A word that starts with `-` is quoted, so that `pastable?/1` tells it from an option of the
  command: a program reads it as an option all the same.

      iex> EhosPlatform.Shell.word("--installation=other")
      "'--installation=other'"
  """
  @spec word(String.t()) :: String.t()
  def word(value) do
    if value =~ ~r/\A[A-Za-z0-9@%+:,.\/_][A-Za-z0-9@%+=:,.\/_-]*\z/,
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

  @doc """
  Whether `command`, a line whose values `word/1` quoted, can be offered to paste into a shell:
  it is `printable?/1`, its quotes are closed, and each of its words, read as a POSIX shell reads
  it, is the same in every shell and reaches the program as a value.

  - A word that holds a `\\` is refused: fish reads `\\'` and `\\\\` inside single quotes, and a
    POSIX shell does not, so the same line gives fish another word.
  - A quoted word that starts with `-` is refused: `word/1` quotes a value that starts with `-`,
    and the program would read it as an option. A word that starts with `-` as it is written is
    the command's own option, so an option's own value that starts with `-` and needs quotes
    cannot be offered.
  - A backslash outside single quotes is taken only before `'`, and inside double quotes only
    before `"` or `$`, which every shell reads alike; `$` before a quote (`$'…'`, `$"…"`) is
    refused. What a shell expands outside single quotes (`$(…)`, `;`) is not checked: only
    `word/1`'s quotes keep a value from it.

      iex> EhosPlatform.Shell.pastable?(~S|ehosctl env remove 'x$(id)'\\''y' --installation office|)
      true

      iex> EhosPlatform.Shell.pastable?("ehosctl env remove '--yes' --installation office")
      false

      iex> EhosPlatform.Shell.pastable?(~S|ehosctl env remove 'a\\b' --installation office|)
      false
  """
  @spec pastable?(String.t()) :: boolean()
  def pastable?(command) do
    with true <- printable?(command),
         {:ok, words} <- words(command, :plain, nil, []) do
      Enum.all?(words, fn {quoted, value} ->
        not String.contains?(value, "\\") and
          not (quoted == :quoted and String.starts_with?(value, "-"))
      end)
    else
      _refused -> false
    end
  end

  # The words of `text` as a POSIX shell splits them, each `{:quoted | :plain, value}` by how its
  # first character is written: spaces between words (`printable?/1` refused a tab), `'…'` as it
  # is, `"…"` with `\\` before `"` or `$`, and `\\` outside quotes before `'`. A backslash before
  # anything else, which fish reads otherwise, and `$` before a quote are `:refused`; an open
  # quote at the end is `:open`.
  defp words(<<>>, :plain, word, words), do: {:ok, Enum.reverse(kept(word, words))}
  defp words(<<>>, _quote, _word, _words), do: :open

  defp words(<<?\s, rest::binary>>, :plain, word, words),
    do: words(rest, :plain, nil, kept(word, words))

  defp words(<<?$, quote, _rest::binary>>, :plain, _word, _words) when quote in [?', ?"],
    do: :refused

  defp words(<<?', rest::binary>>, :plain, word, words),
    do: words(rest, :single, started(word, :quoted), words)

  defp words(<<?", rest::binary>>, :plain, word, words),
    do: words(rest, :double, started(word, :quoted), words)

  defp words(<<?\\, ?', rest::binary>>, :plain, word, words),
    do: words(rest, :plain, added(started(word, :quoted), ?'), words)

  defp words(<<?\\, _rest::binary>>, :plain, _word, _words), do: :refused

  defp words(<<char::utf8, rest::binary>>, :plain, word, words),
    do: words(rest, :plain, added(started(word, :plain), char), words)

  defp words(<<?', rest::binary>>, :single, word, words), do: words(rest, :plain, word, words)

  defp words(<<?", rest::binary>>, :double, word, words), do: words(rest, :plain, word, words)

  defp words(<<?\\, char, rest::binary>>, :double, word, words) when char in [?", ?$],
    do: words(rest, :double, added(word, char), words)

  defp words(<<?\\, _rest::binary>>, :double, _word, _words), do: :refused

  defp words(<<char::utf8, rest::binary>>, quote, word, words),
    do: words(rest, quote, added(word, char), words)

  defp started(nil, quoted), do: {quoted, ""}
  defp started(word, _quoted), do: word

  defp added({quoted, value}, char), do: {quoted, <<value::binary, char::utf8>>}

  defp kept(nil, words), do: words
  defp kept(word, words), do: [word | words]
end
