defmodule EhosRelease.MixLock do
  @moduledoc """
  Reads a `mix.lock` as data, without evaluating it and without creating an atom (T-34).

  A `mix.lock` is Elixir, and evaluating a caller's would run the caller's code in a job that
  calls GitHub's API for it. So it is parsed with `Code.string_to_quoted/2`, every atom kept as
  its name in a string (`static_atoms_encoder`, with `existing_atoms_only: true`), so a crafted
  file cannot fill the atom table, and then read as literals alone: a map, tuples, lists,
  strings, numbers and atoms, which become strings. Anything else, a call or a variable, is a
  refusal.
  """

  @doc """
  The entries of a `mix.lock`, each a map from the dependency's name to its entry, with every
  atom as a string.

      iex> EhosRelease.MixLock.parse(~s(%{"a": {:git, "https://example.com/a.git", "abc", [ref: "abc"]}}))
      {:ok, %{"a" => {"git", "https://example.com/a.git", "abc", [{"ref", "abc"}]}}}

      iex> EhosRelease.MixLock.parse(~s[%{"a": System.halt()}])
      {:error, "mix.lock holds something other than literals"}
  """
  @spec parse(String.t()) :: {:ok, %{String.t() => term()}} | {:error, String.t()}
  def parse(contents) do
    with {:ok, quoted} <- quote_safely(contents),
         {:ok, %{} = entries} <- literal(quoted) do
      {:ok, entries}
    else
      {:ok, _not_a_map} -> {:error, "mix.lock is not a map"}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  The git dependencies of a `mix.lock`: for each, its name, the repository's URL, the commit the
  lock holds, and its options (`sparse`, `ref`, `branch`, `tag`), with string keys.

      iex> EhosRelease.MixLock.git_dependencies(%{
      ...>   "a" => {"git", "https://github.com/o/r.git", "abc", [{"sparse", "packages/a"}]},
      ...>   "b" => {"hex", "b", "1.0.0"}
      ...> })
      [{"a", "https://github.com/o/r.git", "abc", %{"sparse" => "packages/a"}}]
  """
  @spec git_dependencies(%{String.t() => term()}) :: [
          {String.t(), String.t(), String.t(), %{String.t() => term()}}
        ]
  def git_dependencies(entries) do
    entries
    |> Enum.sort()
    |> Enum.flat_map(fn
      {name, {"git", url, commit, opts}} when is_binary(url) and is_binary(commit) ->
        [{name, url, commit, options(opts)}]

      _other ->
        []
    end)
  end

  defp options(opts) when is_list(opts) do
    for {key, value} when is_binary(key) <- opts, into: %{}, do: {key, value}
  end

  defp options(_opts), do: %{}

  defp quote_safely(contents) do
    case Code.string_to_quoted(contents,
           existing_atoms_only: true,
           emit_warnings: false,
           static_atoms_encoder: fn name, _meta -> {:ok, {:atom, name}} end
         ) do
      {:ok, quoted} -> {:ok, quoted}
      {:error, _reason} -> {:error, "mix.lock is not valid Elixir"}
    end
  end

  defp literal({:atom, name}) when is_binary(name), do: {:ok, name}
  defp literal(value) when is_binary(value) or is_number(value), do: {:ok, value}
  defp literal(value) when is_atom(value) and value in [true, false, nil], do: {:ok, value}
  defp literal({:%{}, _meta, pairs}), do: pairs |> literals() |> map_result(&Map.new/1)
  defp literal({:{}, _meta, elements}), do: elements |> literals() |> map_result(&List.to_tuple/1)
  defp literal(list) when is_list(list), do: literals(list)
  defp literal({left, right}), do: [left, right] |> literals() |> map_result(&List.to_tuple/1)
  defp literal(_other), do: {:error, "mix.lock holds something other than literals"}

  defp literals(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case literal(value) do
        {:ok, read} -> {:cont, {:ok, [read | acc]}}
        error -> {:halt, error}
      end
    end)
    |> map_result(&Enum.reverse/1)
  end

  defp map_result({:ok, value}, fun), do: {:ok, fun.(value)}
  defp map_result(error, _fun), do: error
end
