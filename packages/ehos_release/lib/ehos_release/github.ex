defmodule EhosRelease.GitHub do
  @moduledoc """
  GitHub's REST API, as a way out (T-20). A caller names an implementation in `opts[:github]`,
  and `EhosRelease.GitHubImpl` is the default.
  """

  @doc """
  How `head` stands to `base` in `repository`: GitHub's `compare` status, `"ahead"`, `"behind"`,
  `"identical"` or `"diverged"`. A commit `main` contains is `"behind"` or `"identical"`
  (eh-os D-205, "Between releases").
  """
  @callback compare(repository :: String.t(), base :: String.t(), head :: String.t()) ::
              {:ok, String.t()} | {:error, String.t()}

  @doc """
  Every ruleset of `repository` with its rules, conditions and bypass list, as GitHub's
  `GET /repos/{owner}/{repo}/rulesets/{id}` answers each.
  """
  @callback rulesets(repository :: String.t()) :: {:ok, [map()]} | {:error, String.t()}
end

defmodule EhosRelease.GitHubImpl do
  @moduledoc """
  The `EhosRelease.GitHub` that calls `api.github.com` with Req, with the token in `GH_TOKEN`
  when it is set. An error names what failed and its HTTP status, never the response's body.
  """

  @behaviour EhosRelease.GitHub

  @impl true
  def compare(repository, base, head) do
    case get("/repos/#{repository}/compare/#{base}...#{head}") do
      {:ok, %{"status" => status}} when is_binary(status) -> {:ok, status}
      {:ok, _body} -> {:error, "GitHub's compare of #{repository} has no status"}
      {:error, reason} -> {:error, "GitHub's compare of #{repository} #{reason}"}
    end
  end

  @impl true
  def rulesets(repository) do
    case get("/repos/#{repository}/rulesets?per_page=100") do
      {:ok, list} when is_list(list) ->
        Enum.reduce_while(list, {:ok, []}, &ruleset(repository, &1, &2))

      {:ok, _body} ->
        {:error, "GitHub's rulesets of #{repository} are not a list"}

      {:error, reason} ->
        {:error, "GitHub's rulesets of #{repository} #{reason}"}
    end
  end

  defp ruleset(repository, %{"id" => id}, {:ok, acc}) do
    case get("/repos/#{repository}/rulesets/#{id}") do
      {:ok, ruleset} -> {:cont, {:ok, [ruleset | acc]}}
      {:error, reason} -> {:halt, {:error, "GitHub's ruleset #{id} of #{repository} #{reason}"}}
    end
  end

  defp get(path) do
    case Req.get("https://api.github.com" <> path, headers: headers(), retry: :transient) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, "answered #{status}"}
      {:error, _exception} -> {:error, "could not be reached"}
    end
  end

  defp headers do
    base = [
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"}
    ]

    case System.get_env("GH_TOKEN") do
      token when token in [nil, ""] -> base
      token -> [{"authorization", "Bearer " <> token} | base]
    end
  end
end
