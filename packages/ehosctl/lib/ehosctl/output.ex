defmodule Ehosctl.Output do
  @moduledoc """
  How every command answers: words for a person on stdout by default, one JSON document on
  stdout under `--json`, and errors on stderr with an exit code that names their kind.

  The exit codes are a contract with scripts, so a kind keeps its code across versions:

  | Code | Kind | Meaning |
  | --- | --- | --- |
  | 0 | | Done |
  | 1 | `:failed` | The command failed for a reason of its own, which it names |
  | 2 | `:invalid` | The command line, or a variable such as `EHOSCTL_CA_FILE`, is not one `ehosctl` accepts |
  | 3 | `:refused` | EHOS refused the request |
  | 4 | `:not_signed_in` | No installation is signed in to, or its sign-in has expired |
  | 5 | `:unreachable` | The installation did not answer, or what a command waited for may still change |

  `ehosctl init` is the exception it was before: when a step fails, it exits with that step's
  own exit code.

  The words are built from a few shapes, each a function here
  ([T-28](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0028-ehosctl-says-everything-in-a-few-shared-shapes-built-as-tagged-data-and-colours-them-only-on-a-terminal-without-no-color.md)):
  `outcome/2`, `values/1`, `next/1`, `warning/2`, `what_to_do/1`, `progress/1`,
  `tool_output/2` and `list/1`, put together with `lines/1`. They are `t:text/0`: strings and
  Owl's tags. `render/2` escapes every string first, as `shown_lines/1` does, and only then
  colours the tags, so what a server wrote can never carry a code of its own to the terminal.
  A device is coloured only when it is a terminal and `NO_COLOR` is not set; JSON never is.
  """

  @typedoc """
  The words for a person: a string, or Owl data, strings with `Owl.Data.tag/2`'s tags, as the
  shapes build them.
  """
  @type text :: Owl.Data.t()

  @typedoc "A result: the words for a person, and the value `--json` prints."
  @type t :: %{text: text(), json: term()}

  @typedoc "How an outcome ended: done, failed, done with a warning, or nothing changed."
  @type ending :: :done | :failed | :warning | :unchanged

  @type kind :: :failed | :invalid | :refused | :not_signed_in | :unreachable

  @typedoc """
  What a refusal of EHOS's carries beside its sentence, printed under `--json` in the error's
  object: `"code"`, and the other fields `Ehosctl.Refusal.ehos/2` keeps of EHOS's answer.
  """
  @type refusal :: %{optional(String.t()) => term()}

  @codes [failed: 1, invalid: 2, refused: 3, not_signed_in: 4, unreachable: 5]

  @doc "The exit code of each kind of error."
  @spec codes() :: keyword(pos_integer())
  def codes, do: @codes

  @doc "The exit code of a kind of error."
  @spec code(kind()) :: pos_integer()
  def code(kind), do: Keyword.fetch!(@codes, kind)

  # The most bytes of a message `bounded/1` keeps.
  @longest_shown 65_536

  @doc """
  The `--json` flag, for the declaration of a command that can answer in JSON. A command
  without it refuses `--json` as an argument it does not take.
  """
  @spec json_flag() :: keyword()
  def json_flag, do: [json: [long: "--json", help: "Print one JSON document instead of words."]]

  @doc """
  Whether `text` can be printed to a terminal as it is.

  A control character, written by hand or by a server, could move the cursor, rewrite a line or
  set the clipboard. A format character (U+202E, the bidirectional controls) or a line or
  paragraph separator reorders or breaks what is shown around it. Text with any of them is not
  printed.

      iex> Ehosctl.Output.printable?("https://ehos.example.com")
      true

      iex> Ehosctl.Output.printable?("https://ehos.example.com\e[2J")
      false
  """
  @spec printable?(String.t()) :: boolean()
  def printable?(text) when is_binary(text),
    do: String.printable?(text) and not String.match?(text, ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u)

  @doc """
  A moment as a person reads it, in UTC: `DateTime`, or ISO 8601 as `config.json` keeps it.

      iex> Ehosctl.Output.date(~U[2026-10-16 14:02:09Z])
      "16 October 2026, 14:02 UTC"
  """
  @spec date(DateTime.t() | String.t()) :: String.t()
  def date(%DateTime{} = datetime),
    do: datetime |> DateTime.shift_zone!("Etc/UTC") |> Calendar.strftime("%-d %B %Y, %H:%M UTC")

  def date(iso8601) when is_binary(iso8601) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(iso8601)
    date(datetime)
  end

  @doc """
  `rows`, maps from each of `columns` to its text, as a table without borders whose columns are
  in the order of `columns`, as kubectl prints one.
  """
  @spec table([%{String.t() => String.t()}], [String.t()]) :: String.t()
  def table(rows, columns) do
    rows
    |> Owl.Table.new(
      border_style: :none,
      padding_x: 1,
      max_width: :infinity,
      sort_columns: fn a, b ->
        Enum.find_index(columns, &(&1 == a)) <= Enum.find_index(columns, &(&1 == b))
      end
    )
    |> Owl.Data.to_chardata()
    |> IO.chardata_to_string()
    |> String.split("\n")
    |> Enum.map_join("\n", &String.trim_trailing/1)
  end

  @markers %{
    done: {"✓", :green},
    failed: {"✗", :red},
    warning: {"!", :yellow},
    unchanged: {"·", :faint}
  }

  @doc """
  What a command did, in one short sentence after a marker that does not need colour to be
  read: `✓` done, `✗` failed, `!` done with a warning, `·` nothing changed. On a terminal the
  marker is green, red, yellow or dim.

      iex> Ehosctl.Output.outcome(:done, "The server ehos-office is up.")
      ...> |> Ehosctl.Output.render(false)
      ...> |> IO.chardata_to_string()
      "✓ The server ehos-office is up."
  """
  @spec outcome(ending(), text()) :: text()
  def outcome(ending, sentence) do
    {marker, colour} = Map.fetch!(@markers, ending)
    [Owl.Data.tag(marker, colour), " ", sentence]
  end

  @doc """
  Values a person looks for, one on each line, under an outcome: an address, an id, a
  fingerprint, a path, an expiry. The labels are aligned, and a value of several lines keeps
  its lines under its first. On a terminal the label is dim and the value bold.

      iex> Ehosctl.Output.values([{"Address", "203.0.113.10"}, {"SSH host key", "ssh-ed25519"}])
      ...> |> Ehosctl.Output.render(false)
      ...> |> IO.chardata_to_string()
      "  Address        203.0.113.10\\n  SSH host key   ssh-ed25519"
  """
  @spec values([{String.t(), text()}]) :: text()
  def values(pairs) do
    width =
      pairs |> Enum.map(fn {label, _value} -> String.length(label) end) |> Enum.max(fn -> 0 end)

    under = String.duplicate(" ", width + 5)

    pairs
    |> Enum.map(fn {label, value} ->
      [first | rest] = value_lines(value)
      continued = Enum.map(rest, &["\n", under, Owl.Data.tag(&1, :bright)])

      [
        "  ",
        Owl.Data.tag(String.pad_trailing(label, width), :faint),
        "   ",
        Owl.Data.tag(first, :bright) | continued
      ]
    end)
    |> Enum.intersperse("\n")
  end

  defp value_lines(value) do
    case Owl.Data.lines(value) do
      [] -> [""]
      lines -> lines
    end
  end

  @doc """
  The commands a person runs next, each on its own line, ready to copy. On a terminal each
  command is cyan.

      iex> Ehosctl.Output.next(["ehosctl server tunnel --installation office"])
      ...> |> Ehosctl.Output.render(false)
      ...> |> IO.chardata_to_string()
      "Next:\\n  ehosctl server tunnel --installation office"
  """
  @spec next([String.t()]) :: text()
  def next(commands), do: commands("Next:", commands)

  @doc """
  The commands that fix an error, to put under its first line, in the shape `next/1` has.

      iex> Ehosctl.Output.what_to_do(["ehosctl login --installation office"])
      ...> |> Ehosctl.Output.render(false)
      ...> |> IO.chardata_to_string()
      "What to do:\\n  ehosctl login --installation office"
  """
  @spec what_to_do([String.t()]) :: text()
  def what_to_do(commands), do: commands("What to do:", commands)

  defp commands(head, commands),
    do: [head | Enum.map(commands, &["\n  ", Owl.Data.tag(&1, :cyan)])]

  @doc """
  A warning: `! ` and a short head line, yellow on a terminal, and its explanation, when there
  is one, indented under it. `warn/2` prints one.

      iex> Ehosctl.Output.warning("No system keychain.", "The sign-in is kept in a file.")
      ...> |> Ehosctl.Output.render(false)
      ...> |> IO.chardata_to_string()
      "! No system keychain.\\n  The sign-in is kept in a file."
  """
  @spec warning(text(), text() | nil) :: text()
  def warning(head, explanation \\ nil),
    do: [Owl.Data.tag(["! ", head], :yellow) | indented(explanation)]

  defp indented(nil), do: []

  defp indented(text),
    do:
      text
      |> Owl.Data.lines()
      |> Enum.map(&["\n", if(Owl.Data.length(&1) == 0, do: "", else: ["  ", &1])])

  @doc "Prints `warning/2` on stderr."
  @spec warn(text(), text() | nil) :: :ok
  def warn(head, explanation \\ nil),
    do: IO.puts(:stderr, render(warning(head, explanation), colour?(:stderr)))

  @doc """
  Prints a step of a long command on stderr, after `==> `, dim on a terminal, so stdout keeps
  the result alone. The step may hold what a server printed, as cloud-init's errors do
  (ehos-tools#165): `render/2` escapes it.
  """
  @spec progress(text()) :: :ok
  def progress(step),
    do: IO.puts(:stderr, render([Owl.Data.tag("==>", :faint), " ", step], colour?(:stderr)))

  @doc """
  What another program printed, such as `tofu`, `helm` or `kubectl`, under a line that names
  it, each of its lines indented and dim on a terminal, so it is not read as ehosctl's own.

      iex> Ehosctl.Output.tool_output("helm", "Error: timed out\\r\\n")
      ...> |> Ehosctl.Output.render(false)
      ...> |> IO.chardata_to_string()
      "helm printed:\\n  Error: timed out"

      iex> Ehosctl.Output.tool_output("tofu", "") |> Ehosctl.Output.render(false)
      ...> |> IO.chardata_to_string()
      "tofu printed nothing."
  """
  @spec tool_output(String.t(), String.t()) :: text()
  def tool_output(tool, printed) do
    case printed |> String.replace("\r\n", "\n") |> String.trim_trailing("\n") do
      "" ->
        [tool, " printed nothing."]

      printed ->
        lines = printed |> String.split("\n") |> Enum.map(&["\n  ", Owl.Data.tag(&1, :faint)])
        [tool, " printed:" | lines]
    end
  end

  @doc """
  Items of a list, each on its own indented line after `- `, for a list that can hold more
  than two; a list of rows with columns is a `table/2`.

      iex> Ehosctl.Output.list(["office", "ledger"]) |> Ehosctl.Output.render(false)
      ...> |> IO.chardata_to_string()
      "  - office\\n  - ledger"
  """
  @spec list([text()]) :: text()
  def list(items), do: items |> Enum.map(&["  - ", &1]) |> Enum.intersperse("\n")

  @doc """
  `parts`, each on its own line, those that are `nil` left out; `""` is an empty line between
  two parts.

      iex> Ehosctl.Output.lines([Ehosctl.Output.outcome(:unchanged, "Nothing to do."), nil, "", "Bye."])
      ...> |> Ehosctl.Output.render(false)
      ...> |> IO.chardata_to_string()
      "· Nothing to do.\\n\\nBye."
  """
  @spec lines([text() | nil]) :: text()
  def lines(parts), do: parts |> Enum.reject(&is_nil/1) |> Enum.intersperse("\n")

  @doc """
  `text` as a terminal may print it: every string escaped as `shown_lines/1` escapes it, and
  then, when `colour?`, each tag turned into its ANSI codes, and otherwise left out. Escaping
  comes first, so the only codes in what is printed are the tags' own.

      iex> Ehosctl.Output.render(["x ", Owl.Data.tag("\\e[2J", :red)], false)
      ...> |> IO.chardata_to_string()
      ~S(x "\\u{1B}[2J")
  """
  @spec render(text(), boolean()) :: IO.chardata()
  def render(text, colour?), do: text |> map_strings(&shown_lines/1) |> paint(colour?)

  # Every string of `text`, and each character Owl data may hold as an integer, through `fun`,
  # the tags kept.
  defp map_strings(text, fun) when is_binary(text), do: fun.(text)
  defp map_strings(code, fun) when is_integer(code), do: fun.(<<code::utf8>>)
  defp map_strings(%Owl.Tag{data: data} = tag, fun), do: %{tag | data: map_strings(data, fun)}
  defp map_strings(text, fun) when is_list(text), do: Enum.map(text, &map_strings(&1, fun))

  # Owl.Data.to_chardata/1 would colour only when `:elixir, :ansi_enabled` is set, one setting
  # for stdout and stderr alike; each device is decided here instead, so the codes are written
  # explicitly. An inner tag's end puts back the tags around it.
  defp paint(text, false), do: Owl.Data.untag(text)
  defp paint(text, true), do: coloured(text, [])

  defp coloured(%Owl.Tag{sequences: sequences, data: data}, around) do
    [
      IO.ANSI.format_fragment(sequences, true),
      coloured(data, around ++ sequences),
      IO.ANSI.reset(),
      IO.ANSI.format_fragment(around, true)
    ]
  end

  defp coloured(text, around) when is_list(text), do: Enum.map(text, &coloured(&1, around))
  defp coloured(string, _around), do: string

  # A message without its tags, as JSON prints it; bytes that are not UTF-8 are kept.
  defp plain(text), do: text |> map_strings(& &1) |> Owl.Data.untag() |> IO.iodata_to_binary()

  # Colour only on a terminal, and not when `NO_COLOR` holds anything (https://no-color.org).
  defp colour?(device) do
    Ehosctl.SystemEnv.current().get("NO_COLOR") in [nil, ""] and terminal?(device)
  end

  defp terminal?(:stdio), do: Ehosctl.Terminal.current().output_terminal?()
  defp terminal?(:stderr), do: Ehosctl.Terminal.current().error_terminal?()

  @doc """
  `value` as indented JSON for a person to read, with every character that would reorder or
  break the lines around it (`printable?/1`) escaped, as JSON allows inside a string.

      iex> Ehosctl.Output.pretty_json([1, nil, <<0x202E::utf8>>])
      ~S([1,null,"\\u202E"])
  """
  @spec pretty_json(term()) :: String.t()
  def pretty_json(value) do
    value
    |> :json.format(fn
      nil, _encode, _state -> "null"
      other, encode, state -> :json.format_value(other, encode, state)
    end)
    |> IO.iodata_to_binary()
    |> String.trim_trailing()
    |> escaped()
  end

  @doc """
  `value` as JSON on one line, with every character `printable?/1` refuses escaped.

      iex> Ehosctl.Output.json(%{"computer_id" => "01a1"})
      ~S({"computer_id":"01a1"})
  """
  @spec json(term()) :: String.t()
  def json(value), do: value |> JSON.encode!() |> escaped()

  # JSON escapes only what is below U+0020; a bidirectional override or a C1 control a server
  # sent would otherwise reach the terminal as it is.
  defp escaped(json), do: String.replace(json, ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u, &escape/1)

  # Inside a string, the only place such a character can be, `\uXXXX`, as a surrogate pair
  # past the Basic Multilingual Plane. A line break between JSON's own tokens stays.
  defp escape("\n"), do: "\n"

  defp escape(<<code::utf8>>) when code > 0xFFFF do
    code = code - 0x10000
    escape16(0xD800 + Bitwise.bsr(code, 10)) <> escape16(0xDC00 + Bitwise.band(code, 0x3FF))
  end

  defp escape(<<code::utf8>>), do: escape16(code)

  defp escape16(code),
    do: "\\u" <> String.pad_leading(Integer.to_string(code, 16), 4, "0")

  @doc """
  Prints a result, as words or as JSON, and returns exit code 0. The words go through
  `render/2`, which escapes them as `shown_lines/1` does, since a command may say what a server
  wrote, as `ehosctl server status` says what the node reports (ehos-tools#165), and colours
  them only on a terminal; the JSON has every character `printable?/1` refuses escaped, as
  `pretty_json/1` has.
  """
  @spec result(t(), boolean()) :: 0
  def result(%{json: json}, true), do: tap(0, fn _ -> IO.puts(json(json)) end)

  def result(%{text: text}, false),
    do: tap(0, fn _ -> IO.puts(render(text, colour?(:stdio))) end)

  @doc """
  Prints an error on stderr, as words or as a JSON object, and returns its kind's exit code.

  Under `--json`, the object is `{"error": {"kind", "message"}}`, and the fields of `refusal`
  beside them: EHOS's `code`, and at a count of ephemeral environments the environments that hold
  it (`Ehosctl.AtCount`), so a script matches a refusal by its code, not its sentence. As words,
  the message already says what `refusal` holds; where it says more than the sentence, as the
  environments at the count, `refusal`'s `"message"` is the sentence `--json` prints.

  A message may carry what another program or a server said: a failing `helm`'s output holds a
  revision's description, which the cluster writes (ehos-tools#165). As words, it is printed
  through `render/2`, after `ehosctl:`, red on a terminal; as JSON, without its tags, the encoder
  escapes it, and a byte that is not UTF-8 becomes U+FFFD. Either way it is cut at 64 KiB
  (`bounded/1`), whatever was added to it on the way; as words, each of its strings is. The
  fields of `refusal` are bounded by what keeps them, `Ehosctl.AtCount` keeping at most 20
  environments, and the text of each by the 1 MiB an answer of EHOS's may be.
  """
  @spec error(kind(), text(), boolean(), refusal()) :: pos_integer()
  def error(kind, message, json?, refusal \\ %{})

  def error(kind, message, true, refusal) do
    {message, refusal} = Map.pop(refusal, "message", message)
    # JSON takes UTF-8 alone: bytes a tool printed that are not become U+FFFD.
    message = message |> plain() |> bounded() |> String.replace_invalid()
    IO.puts(:stderr, json(%{error: Map.merge(refusal, %{kind: kind, message: message})}))
    code(kind)
  end

  def error(kind, message, false, _refusal) do
    words = [Owl.Data.tag("ehosctl:", :red), " ", map_strings(message, &bounded/1)]
    IO.puts(:stderr, render(words, colour?(:stderr)))
    code(kind)
  end

  @doc """
  `text` cut at 64 KiB, about 800 lines, with `…` after the cut: what a server or a program said
  can be any length, and more is not for a person to read. A manifest's refusal names 50 reasons
  of up to 256 code points each, which is kept whole. Text that is UTF-8 is cut between
  characters; bytes that are not are kept as they are, for `shown_lines/1` to escape.

      iex> Ehosctl.Output.bounded("short")
      "short"
  """
  @spec bounded(binary()) :: binary()
  def bounded(text) when byte_size(text) > @longest_shown do
    cut = binary_part(text, 0, @longest_shown)
    if(String.valid?(text), do: String.replace_invalid(cut, ""), else: cut) <> "…"
  end

  def bounded(text), do: text

  @doc """
  `text`, line by line, as a terminal may print it. A line that holds a character a terminal
  would act on, or that hides or reorders text, is printed quoted, with each such character
  escaped as `\\u{…}` and each byte that is not UTF-8 as `\\x…`; the rest of the line, however
  long, stays as it is. Those characters are the controls, the line and paragraph separators and
  the format characters, but for the zero-width joiner and non-joiner, which words in some
  scripts and emoji hold. Tabs become spaces and Windows line ends Unix ones, as a tool's output
  has them.

      iex> Ehosctl.Output.shown_lines("helm failed:\\nError: \\e[2Jboom\\tthere")
      "helm failed:\\n" <> ~S("Error: \\u{1B}[2Jboom    there")
  """
  @spec shown_lines(String.t()) :: String.t()
  def shown_lines(text) when is_binary(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\t", "    ")
    |> String.split("\n")
    |> Enum.map_join("\n", &shown_line/1)
  end

  # A character a terminal acts on, or that hides or reorders the text around it.
  @acted_on ~r/[\p{Cc}\p{Zl}\p{Zp}]|(?!\x{200C}|\x{200D})\p{Cf}/u

  defp shown_line(line) do
    if String.valid?(line) and not String.match?(line, @acted_on),
      do: line,
      else: "\"" <> escaped_line(line) <> "\""
  end

  # One pass over each valid chunk: a backslash, a quote, or a character a terminal acts on.
  @escaped ~r/\\|"|[\p{Cc}\p{Zl}\p{Zp}]|(?!\x{200C}|\x{200D})\p{Cf}/u

  defp escaped_line(line) do
    line
    |> String.chunk(:valid)
    |> Enum.map_join(&escaped_chunk/1)
  end

  defp escaped_chunk(chunk) do
    if String.valid?(chunk),
      do: Regex.replace(@escaped, chunk, &escaped_character/1),
      else: for(<<byte <- chunk>>, into: "", do: "\\x" <> hex(byte, 2))
  end

  defp escaped_character("\\"), do: "\\\\"
  defp escaped_character("\""), do: "\\\""

  defp escaped_character(character),
    do: "\\u{" <> (character |> String.to_charlist() |> hd() |> hex(1)) <> "}"

  defp hex(code, digits), do: code |> Integer.to_string(16) |> String.pad_leading(digits, "0")
end
