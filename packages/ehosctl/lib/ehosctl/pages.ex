defmodule Ehosctl.Pages do
  @moduledoc """
  A list EHOS's API gives in pages, each naming the next in a `Link: rel="next"` header (RFC
  8288): the people (`/api/v1/people`), the audit record (`/api/v1/audit`) and a person's activity
  (`/api/v1/me/activity`).

  The next page is asked of the installation's own address, with the path and query the link
  gives, and only when its path is the list's: a link elsewhere would carry the credential there.
  A link that goes back to a page already read, or more pages than any list has, ends the read
  as an error rather than going round.
  """

  alias Ehosctl.Api
  alias Ehosctl.Config

  @max_pages 10_000

  @typedoc """
  How to read one list: the `:key` of the items in each page's body, `:valid?`, whether an item is
  one, and `:only`, the fields of it that are kept.
  """
  @type list_spec :: [key: String.t(), valid?: (term() -> boolean()), only: (map() -> map())]

  @doc """
  The items of the list at `path` (its first page, with its query), at most `limit` of them
  (`nil` for every one), following each page's link, and whether more remain.
  """
  @spec read(
          {Config.name(), Config.installation()},
          String.t(),
          list_spec(),
          pos_integer() | nil,
          keyword()
        ) :: {:ok, [map()], boolean()} | Api.error()
  def read(installation, path, spec, limit, opts) do
    list_path = path |> URI.parse() |> Map.fetch!(:path)
    pages(installation, path, list_path, spec, {[], 0, MapSet.new([path])}, limit, opts)
  end

  # `pages` are those read so far, newest first; `asked` the paths, this one among them, so a link
  # that goes back to one ends the list rather than going round. It starts as `MapSet.new([path])`
  # rather than empty: Elixir compiles `MapSet.new()` to a literal struct, which Dialyzer then
  # takes for a set built by hand.
  defp pages(installation, path, list_path, spec, {pages, count, asked}, limit, opts) do
    key = Keyword.fetch!(spec, :key)

    with {:ok, answer} <- get(installation, path, opts),
         %{status: 200, body: %{^key => page}} when is_list(page) <- answer,
         true <- Enum.all?(page, spec[:valid?]) || Api.unexpected(installation) do
      page = Enum.map(page, spec[:only])
      pages = [page | pages]
      count = count + length(page)
      next = next(answer.headers["link"], list_path)
      items = fn -> pages |> Enum.reverse() |> Enum.concat() end

      cond do
        limit != nil and count >= limit ->
          more? = count > limit or more_after?(installation, next, spec, asked, opts)
          {:ok, Enum.take(items.(), limit), more?}

        next == nil or page == [] ->
          {:ok, items.(), false}

        true ->
          next_page(installation, next, list_path, spec, {pages, count, asked}, limit, opts)
      end
    else
      %{} = answer -> Api.refusal(answer, installation)
      error -> error
    end
  end

  defp next_page(installation, :unreadable, _list_path, _spec, _read, _limit, _opts),
    do: {:error, :failed, "#{url(installation)} gave a next page ehosctl cannot follow."}

  defp next_page(installation, next, list_path, spec, {pages, count, asked}, limit, opts) do
    if MapSet.member?(asked, next) or MapSet.size(asked) >= @max_pages do
      {:error, :failed,
       "#{url(installation)} gave as the next page one already read, or more pages than " <>
         "any list has, so the list cannot be finished."}
    else
      asked = MapSet.put(asked, next)
      pages(installation, next, list_path, spec, {pages, count, asked}, limit, opts)
    end
  end

  # Whether the page after the last one read holds anything: EHOS names a next page whenever one
  # is full, so a full last page is followed by an empty one. A next page that cannot be read, or
  # was read already, is taken as more, which a person can look for with a larger limit.
  defp more_after?(_installation, nil, _spec, _asked, _opts), do: false
  defp more_after?(_installation, :unreadable, _spec, _asked, _opts), do: true

  defp more_after?(installation, next, spec, asked, opts) do
    key = Keyword.fetch!(spec, :key)

    with false <- MapSet.member?(asked, next),
         {:ok, %{status: 200, body: %{^key => page}}} when is_list(page) <-
           get(installation, next, opts) do
      page != []
    else
      _unknown -> true
    end
  end

  defp get(installation, path, opts) do
    case Api.answer(installation, :get, path, nil, opts) do
      {:error, kind, message, :sent} -> {:error, kind, message}
      result -> result
    end
  end

  # The link whose relations include `next` (RFC 8288, in any case, among others and after other
  # parameters): its path and query, when the path is the list's; `:unreadable` for a next page
  # anywhere else, `nil` for none.
  defp next(nil, _list_path), do: nil

  defp next(header, list_path) do
    target =
      Regex.scan(~r/<([^>]*)>([^<]*)/, header)
      |> Enum.find_value(fn [_, target, parameters] ->
        if next?(parameters), do: target
      end)

    case target && URI.parse(target) do
      nil -> nil
      %URI{path: ^list_path, query: query} when is_binary(query) -> list_path <> "?" <> query
      _other -> :unreadable
    end
  end

  defp next?(parameters) do
    case Regex.run(~r/;\s*rel\s*=\s*(?:"([^"]*)"|([^\s;,]+))/i, parameters) do
      [_, quoted | rest] ->
        (quoted <> Enum.join(rest)) |> String.downcase() |> String.split() |> Enum.member?("next")

      nil ->
        false
    end
  end

  defp url({_name, installation}), do: installation["url"]
end
