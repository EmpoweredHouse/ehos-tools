defmodule EhosRelease.PinCheck do
  @moduledoc """
  The two checks eh-os D-205 asks of a pin, each answering a refusal per pin that fails it:

  - `on_main/2`, on every pull request: the pin names a commit the producer's `main` contains
    (`compare/main...<commit>` is `behind` or `identical`), since GitHub serves a fork's commit,
    or an unmerged branch's, under the producer's name. An untagged commit of `main` passes:
    that is what D-205 allows between releases.
  - `tagged/2`, before a release opens and again on its merge commit: a protected release tag of
    the pinned thing's own prefix names the pin (`EhosRelease.Producers`). A tag is protected when
    a ruleset that is active, that refuses its update and its deletion, and that no one may
    bypass covers its prefix, as "Release tags stay what they were" does. A ruleset the job cannot
    read is a refusal, not a pass (T-34).

  Tags are read once per producer with `git ls-remote`, and rulesets once per producer through
  the API. `opts[:git]` and `opts[:github]` name the implementations, `EhosRelease.GitImpl` and
  `EhosRelease.GitHubImpl` by default.
  """

  alias EhosRelease.{Pin, Producers}

  @doc "A refusal for each pin no protected release tag of its prefix names."
  @spec tagged([Pin.t()], keyword()) :: [String.t()]
  def tagged(pins, opts \\ []) do
    git = Keyword.get(opts, :git, EhosRelease.GitImpl)
    github = Keyword.get(opts, :github, EhosRelease.GitHubImpl)
    producers = per_producer(pins, &tags_and_protection(&1, git, github))
    Enum.flat_map(pins, &tagged_refusal(&1, producers))
  end

  @doc "A refusal for each pin that names a commit its producer's `main` does not contain."
  @spec on_main([Pin.t()], keyword()) :: [String.t()]
  def on_main(pins, opts \\ []) do
    git = Keyword.get(opts, :git, EhosRelease.GitImpl)
    github = Keyword.get(opts, :github, EhosRelease.GitHubImpl)
    tags = per_producer(Enum.reject(pins, &Pin.commit?/1), &git.tags/1)
    Enum.flat_map(pins, &on_main_refusal(&1, tags, github))
  end

  @doc """
  The prefixes, of those given, that a ruleset among `rulesets` protects: active, on tags, with
  rules refusing both `update` and `deletion`, its include naming `refs/tags/<prefix>*` (or
  `~ALL`), no exclude matching a tag of the prefix, and no one in its bypass list. A bypass list
  GitHub does not show is read as empty, as GitHub shows it only to whoever may change it.

      iex> EhosRelease.PinCheck.protected_prefixes([%{
      ...>   "target" => "tag", "enforcement" => "active", "bypass_actors" => [],
      ...>   "rules" => [%{"type" => "update"}, %{"type" => "deletion"}],
      ...>   "conditions" => %{"ref_name" => %{"include" => ["refs/tags/v*"], "exclude" => []}}
      ...> }], ["v", "ehos_release-v"])
      ["v"]
  """
  @spec protected_prefixes([map()], [String.t()]) :: [String.t()]
  def protected_prefixes(rulesets, prefixes) do
    Enum.filter(prefixes, fn prefix -> Enum.any?(rulesets, &protects?(&1, prefix)) end)
  end

  defp protects?(%{"target" => "tag", "enforcement" => "active"} = ruleset, prefix) do
    types = for %{"type" => type} <- Map.get(ruleset, "rules", []), do: type
    ref_name = get_in(ruleset, ["conditions", "ref_name"]) || %{}
    include = Map.get(ref_name, "include", [])
    exclude = Map.get(ref_name, "exclude", [])
    sample = "refs/tags/#{prefix}1.0.0"

    "update" in types and "deletion" in types and Map.get(ruleset, "bypass_actors", []) == [] and
      ("refs/tags/#{prefix}*" in include or "~ALL" in include) and
      not Enum.any?(exclude, &glob_match?(&1, sample))
  end

  defp protects?(_ruleset, _prefix), do: false

  defp glob_match?(pattern, ref) do
    regex = pattern |> Regex.escape() |> String.replace("\\*", ".*")
    ref =~ Regex.compile!("\\A" <> regex <> "\\z")
  end

  defp per_producer(pins, fun) do
    pins
    |> Enum.map(& &1.repository)
    |> Enum.uniq_by(&String.downcase/1)
    |> Map.new(fn repository -> {String.downcase(repository), fun.(repository)} end)
  end

  defp tags_and_protection(repository, git, github) do
    with {:ok, tags} <- git.tags(repository),
         {:ok, rulesets} <- github.rulesets(repository) do
      {:ok, tags, protected_prefixes(rulesets, Producers.all_prefixes(repository))}
    end
  end

  defp tagged_refusal(%Pin{} = pin, producers) do
    with {:ok, prefixes} <- prefixes(pin),
         {:ok, tags, protected} <- Map.fetch!(producers, String.downcase(pin.repository)) do
      prefixes |> Enum.filter(&(&1 in protected)) |> tagged_by(pin, prefixes, tags)
    else
      {:error, reason} -> ["#{Pin.describe(pin)}: #{reason}"]
    end
  end

  defp tagged_by(protected, pin, prefixes, tags) do
    if Enum.any?(tags, fn {tag, commit} -> names?(pin, tag, commit, protected) end),
      do: [],
      else: ["#{Pin.describe(pin)}, which no protected tag #{wanted(prefixes)} names"]
  end

  defp names?(pin, tag, commit, protected) do
    named = if Pin.commit?(pin), do: commit == pin.ref, else: tag == pin.ref
    named and Enum.any?(protected, &release_tag?(tag, &1))
  end

  defp release_tag?(tag, prefix) do
    String.starts_with?(tag, prefix) and
      String.replace_prefix(tag, prefix, "") =~ ~r/\A\d+\.\d+\.\d+\z/
  end

  defp wanted(prefixes), do: Enum.map_join(prefixes, " or ", &"#{&1}X.Y.Z")

  defp prefixes(pin) do
    case Producers.prefixes(pin.repository, pin.path) do
      {:ok, prefixes} -> {:ok, prefixes}
      :error -> {:error, "#{pin.repository} releases nothing from #{inspect(pin.path)}"}
    end
  end

  defp on_main_refusal(%Pin{} = pin, tags, github) do
    with {:ok, commit} <- commit_of(pin, tags),
         {:ok, status} <- github.compare(pin.repository, "main", commit) do
      if status in ["behind", "identical"],
        do: [],
        else: ["#{Pin.describe(pin)}, which is #{status} of its main, not on it"]
    else
      {:error, reason} -> ["#{Pin.describe(pin)}: #{reason}"]
    end
  end

  defp commit_of(pin, tags) do
    if Pin.commit?(pin) do
      {:ok, pin.ref}
    else
      tags |> Map.fetch!(String.downcase(pin.repository)) |> tag_commit(pin.ref)
    end
  end

  defp tag_commit({:ok, tags}, tag) do
    case Map.fetch(tags, tag) do
      {:ok, commit} -> {:ok, commit}
      :error -> {:error, "no tag #{tag} exists"}
    end
  end

  defp tag_commit({:error, _reason} = error, _tag), do: error
end
