defmodule Ehosctl.Audit do
  @moduledoc """
  `ehosctl audit [--limit N]`: the audit record, every decision EHOS made, allowed and refused,
  inside the scopes where the person holds `ehos.audit.read`, newest first, as the console's Audit
  page shows it (eh-os
  [`docs/audit-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/audit-api.md),
  D-39). It follows the record's pages up to `--limit` rows. A refused read is recorded by EHOS.

  `rows/3` and `table/2` read and print the rows for `ehosctl activity` too, which reads the same
  rows of the person's own.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Output
  alias Ehosctl.Pages
  alias Ehosctl.Refusal

  @default_limit 100
  @max_limit 10_000
  @page 500

  @impl Ehosctl.Command
  def name, do: :audit

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def spec,
    do: [
      about:
        "List the audit record's newest decisions, allowed and refused, where you may read it.",
      options: [limit: limit_option()],
      flags: Output.json_flag()
    ]

  @doc "The `--limit` option `audit` and `activity` take."
  @spec limit_option() :: keyword()
  def limit_option,
    do: [
      long: "--limit",
      value_name: "N",
      parser: :integer,
      help: "How many rows, newest first, up to #{@max_limit}; #{@default_limit} unless given."
    ]

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], parsed, opts), do: listed("/api/audit", parsed.options.limit, opts)

  @doc """
  The rows of the list at `path`, `/api/audit` or `/api/me/activity`, at most `limit` of them
  (#{@default_limit} when nil), as a command's result.
  """
  @spec listed(String.t(), integer() | nil, keyword()) :: Ehosctl.Command.result()
  def listed(path, limit, opts) do
    limit = limit || @default_limit

    # Every row is held before it is printed, so a limit is one a terminal can show.
    if limit < 1 or limit > @max_limit do
      {:error, :invalid, "--limit is a whole number from 1 to #{@max_limit}."}
    else
      with {:ok, rows, more?} <- rows(path, limit, opts) do
        {:ok, %{text: table(rows, more? and limit), json: %{events: rows, more: more?}}}
      end
    end
  end

  @doc """
  The rows of the list at `path`, at most `limit`, following its pages, and whether more remain.
  """
  @spec rows(String.t(), pos_integer(), keyword()) ::
          {:ok, [map()], boolean()} | {:error, Output.kind(), String.t()}
  def rows(path, limit, opts) do
    installation = Keyword.fetch!(opts, :installation)
    # One row more than asked tells whether more remain, without asking for the page after.
    query = URI.encode_query(limit: min(limit + 1, @page))

    Pages.read(
      installation,
      path <> "?" <> query,
      [key: "events", valid?: &row?/1, only: &only_row/1],
      limit,
      opts
    )
  end

  @doc """
  Rows as a table, newest first, saying when older ones remain beyond `limit`, the limit they were
  read to, or `false` when none do.
  """
  @spec table([map()], pos_integer() | false) :: String.t()
  def table([], _more), do: "No decisions."

  def table(rows, more) do
    table =
      rows
      |> Enum.map(fn row ->
        %{
          "WHEN" => Refusal.shown(row["occurred_at"]),
          "WHO" => who(row),
          "ACTION" => Refusal.shown(row["action"]),
          "OUTCOME" => outcome(row),
          "WHERE" => where(row),
          "ABOUT" => text(row["subject"]),
          "DETAILS" => details(row["details"])
        }
      end)
      |> Output.table(["WHEN", "WHO", "ACTION", "OUTCOME", "WHERE", "ABOUT", "DETAILS"])

    case more do
      false -> table
      @max_limit -> table <> "\nOlder decisions remain, past the #{@max_limit} a listing reads."
      _limit -> table <> "\nOlder decisions remain: a larger --limit reads further."
    end
  end

  @texts ~w(id occurred_at via action outcome)
  @texts_or_null ~w(actor capability reason application environment subject)

  defp row?(%{"details" => details} = row) when is_map(details),
    do:
      Enum.all?(@texts, &is_binary(row[&1])) and
        Enum.all?(@texts_or_null, &(is_nil(row[&1]) or is_binary(row[&1])))

  defp row?(_row), do: false

  defp only_row(row), do: Map.take(row, @texts ++ @texts_or_null ++ ["details"])

  defp who(%{"actor" => actor}) when is_binary(actor), do: Refusal.shown(actor)
  defp who(%{"via" => "release"}), do: "a release command"
  defp who(_row), do: "nobody signed in"

  defp outcome(%{"outcome" => outcome, "reason" => reason}) when is_binary(reason),
    do: "#{Refusal.shown(outcome)}: #{Refusal.shown(reason)}"

  defp outcome(%{"outcome" => outcome}), do: Refusal.shown(outcome)

  defp where(%{"application" => nil}), do: "the whole platform"
  defp where(%{"application" => app, "environment" => nil}), do: Refusal.shown(app)

  defp where(%{"application" => app, "environment" => env}),
    do: "#{Refusal.shown(app)} in #{Refusal.shown(env)}"

  defp details(details) when map_size(details) == 0, do: ""
  defp details(details), do: details |> JSON.encode!() |> Refusal.shown()

  defp text(nil), do: ""
  defp text(value), do: Refusal.shown(value)
end
