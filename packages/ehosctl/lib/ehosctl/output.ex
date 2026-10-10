defmodule Ehosctl.Output do
  @moduledoc """
  How every command answers: words for a person on stdout by default, one JSON document on
  stdout under `--json`, and errors on stderr with an exit code that names their kind.

  The exit codes are a contract with scripts, so a kind keeps its code across versions:

  | Code | Kind | Meaning |
  | --- | --- | --- |
  | 0 | | Done |
  | 1 | `:failed` | The command failed for a reason of its own, which it names |
  | 2 | `:invalid` | The command line is not one `ehosctl` accepts |
  | 3 | `:refused` | EHOS refused the request |
  | 4 | `:not_signed_in` | No installation is signed in to, or its sign-in has expired |
  | 5 | `:unreachable` | The installation did not answer |

  `ehosctl init` is the exception it was before: when a step fails, it exits with that step's
  own exit code.
  """

  @typedoc "A result: the words for a person, and the value `--json` prints."
  @type t :: %{text: IO.chardata(), json: term()}

  @type kind :: :failed | :invalid | :refused | :not_signed_in | :unreachable

  @codes [failed: 1, invalid: 2, refused: 3, not_signed_in: 4, unreachable: 5]

  @doc "The exit code of each kind of error."
  @spec codes() :: keyword(pos_integer())
  def codes, do: @codes

  @doc "The exit code of a kind of error."
  @spec code(kind()) :: pos_integer()
  def code(kind), do: Keyword.fetch!(@codes, kind)

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
  Prints a result, as words or as JSON, and returns exit code 0. The JSON has every character
  `printable?/1` refuses escaped, as `pretty_json/1` has.
  """
  @spec result(t(), boolean()) :: 0
  def result(%{json: json}, true), do: tap(0, fn _ -> IO.puts(json(json)) end)

  def result(%{text: text}, false), do: tap(0, fn _ -> IO.puts(text) end)

  @doc """
  Prints an error on stderr, as one line of words or as a JSON object, and returns its kind's
  exit code.
  """
  @spec error(kind(), String.t(), boolean()) :: pos_integer()
  def error(kind, message, json?) do
    line =
      if json?,
        do: json(%{error: %{kind: kind, message: message}}),
        else: "ehosctl: " <> message

    IO.puts(:stderr, line)
    code(kind)
  end
end
