defmodule Ehosctl.Source do
  @moduledoc """
  Where a deployment came from, as EHOS gives it beside the digest (eh-os
  [D-129](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0129-a-deployment-shows-beside-its-digest-the-github-run-its-credential-was-exchanged-for-or-what-its-deployer-states.md),
  [`docs/deployments-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/deployments-api.md)).
  It is a label: what is approved and pinned stays the digest.

  EHOS sets its `"kind"`, and `ehosctl` tells the two apart by it, never by the text that follows:

    * `"github_run"`: the GitHub run whose token the pipeline exchanged for its credential, as that
      token named it, printed "from GitHub's token: …";
    * `"stated"`: the commit and ref the person who deployed it gave, printed "stated by …: …",
      never as if checked.

  A deployment with neither has none, and nothing is printed for it; nor for a kind a later EHOS
  adds, which `--json` keeps by its kind alone. A source of another shape is dropped, not the
  answer it came in: it is a label, and a deployment decided is still decided.

  `ehosctl deploy --commit --ref` states them. Their form is checked here as EHOS checks it, so a
  statement EHOS would refuse is refused before anything is sent; their truth is checked by no one.
  """

  alias Ehosctl.Refusal

  @max_ref_bytes 255

  @typedoc "A deployment's `source`, as EHOS gives it, or `nil`."
  @type t :: %{String.t() => term()} | nil

  @github_run ~w(kind repository ref commit event run_id run_attempt)
  @stated ~w(kind commit ref stated_by)

  @doc """
  `source` kept to the fields read, so nothing else it holds reaches a script under `--json`: a kind
  `ehosctl` knows with its fields, each of its type or null; another kind by its `kind` alone; `nil`
  for none, and for one of another shape.

      iex> Ehosctl.Source.kept(%{"kind" => "stated", "ref" => "refs/heads/main", "extra" => 1})
      %{"kind" => "stated", "ref" => "refs/heads/main"}

      iex> Ehosctl.Source.kept(%{"kind" => "github_run", "run_id" => "18512345678"})
      nil
  """
  @spec kept(term()) :: t()
  def kept(%{"kind" => "github_run"} = source) do
    if Enum.all?(~w(repository ref commit event), &text_or_nil?(source[&1])) and
         Enum.all?(~w(run_id run_attempt), &integer_or_nil?(source[&1])),
       do: Map.take(source, @github_run)
  end

  def kept(%{"kind" => "stated"} = source) do
    if Enum.all?(~w(commit ref stated_by), &text_or_nil?(source[&1])),
      do: Map.take(source, @stated)
  end

  def kept(%{"kind" => kind}) when is_binary(kind), do: %{"kind" => kind}
  def kept(_source), do: nil

  @doc "`body` with its `\"source\"` kept (`kept/1`), when it has one."
  @spec keeping(map()) :: map()
  def keeping(%{"source" => source} = body), do: %{body | "source" => kept(source)}
  def keeping(body), do: body

  @doc """
  The line that says where a deployment came from, or `nil` when it has no source `ehosctl` knows.

      iex> Ehosctl.Source.line(%{"kind" => "github_run", "repository" => "example/ledger",
      ...>   "ref" => "refs/pull/42/merge", "commit" => "0123456789abcdef0123456789abcdef01234567",
      ...>   "event" => "pull_request", "run_id" => 18512345678, "run_attempt" => 1})
      "from GitHub's token: example/ledger, pull request #42, test-merge commit 0123456789abcdef0123456789abcdef01234567, run 18512345678 (attempt 1)"

      iex> Ehosctl.Source.line(%{"kind" => "stated", "commit" => nil, "ref" => "refs/tags/v1.2.0",
      ...>   "stated_by" => "ada@example.com"})
      "stated by ada@example.com: ref refs/tags/v1.2.0"

      iex> Ehosctl.Source.line(nil)
      nil
  """
  @spec line(t()) :: String.t() | nil
  def line(%{"kind" => "github_run"} = source) do
    pull? = is_binary(source["ref"]) and source["ref"] =~ ~r{\Arefs/pull/\d+/merge\z}

    parts =
      [
        shown(source["repository"]),
        ref(source["ref"]),
        commit(source["commit"], pull?),
        run(source["run_id"], source["run_attempt"])
      ]
      |> Enum.reject(&is_nil/1)

    "from GitHub's token: " <> Enum.join(parts, ", ")
  end

  def line(%{"kind" => "stated"} = source) do
    stated =
      [commit(source["commit"], false), source["ref"] && "ref " <> shown(source["ref"])]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    "stated by #{shown(source["stated_by"] || "someone EHOS does not name")}: #{stated}"
  end

  def line(_source), do: nil

  # For a pull request, its number; a branch or a tag by its name; another ref as it is.
  defp ref(nil), do: nil

  defp ref(ref) do
    case Regex.run(~r{\Arefs/(?:pull/(\d+)/merge|heads/(.+)|tags/(.+))\z}, ref) do
      [_, pull] -> "pull request ##{pull}"
      [_, "", branch] -> "branch " <> shown(branch)
      [_, "", "", tag] -> "tag " <> shown(tag)
      nil -> "ref " <> shown(ref)
    end
  end

  # A pull request's run is of the commit GitHub merged it into its base for, said to be that.
  defp commit(nil, _pull?), do: nil
  defp commit(commit, true), do: "test-merge commit " <> shown(commit)
  defp commit(commit, false), do: "commit " <> shown(commit)

  defp run(nil, _attempt), do: nil
  defp run(id, nil), do: "run #{id}"
  defp run(id, attempt), do: "run #{id} (attempt #{attempt})"

  defp shown(nil), do: nil
  defp shown(text), do: Refusal.shown(text)

  @doc """
  What `ehosctl deploy` states, from `--commit` and `--ref`, each optional: `{:ok, params}` to send,
  empty when neither is given, or the refusal of one outside the form EHOS takes.
  """
  @spec stated(String.t() | nil, String.t() | nil) ::
          {:ok, keyword(String.t())} | {:error, :invalid, String.t()}
  def stated(commit, ref) do
    cond do
      commit && not commit?(commit) ->
        {:error, :invalid,
         "--commit #{Refusal.shown(commit)} is refused: a commit is 40 or 64 lowercase " <>
           "hexadecimal characters."}

      ref && not ref?(ref) ->
        {:error, :invalid,
         "--ref #{Refusal.shown(ref)} is refused: a ref follows git's rules for a ref name, " <>
           "in printable ASCII, at most #{@max_ref_bytes} bytes."}

      true ->
        {:ok, Enum.reject([commit: commit, ref: ref], &is_nil(elem(&1, 1)))}
    end
  end

  defp commit?(value), do: value =~ ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/

  # As eh-os's Ehos.Deployments.Source checks it: git check-ref-format, as far as a name's text
  # goes, and printable ASCII but space.
  defp ref?(value) do
    byte_size(value) in 1..@max_ref_bytes and value =~ ~r/\A[\x21-\x7e]+\z/ and
      not String.contains?(value, ["..", "@{", "//", "~", "^", ":", "?", "*", "[", "\\"]) and
      value != "@" and not String.starts_with?(value, "/") and
      not String.ends_with?(value, ["/", "."]) and
      not Enum.any?(
        String.split(value, "/"),
        &(String.starts_with?(&1, ".") or String.ends_with?(&1, ".lock"))
      )
  end

  defp text_or_nil?(value), do: is_nil(value) or is_binary(value)
  defp integer_or_nil?(value), do: is_nil(value) or is_integer(value)
end
