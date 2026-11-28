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

  @doc """
  The state of issue `number` of `repository`, `"open"` or `"closed"`. Its title and text are
  not read: anyone may write them in a public repository (T-34).
  """
  @callback issue_state(repository :: String.t(), number :: pos_integer()) ::
              {:ok, String.t()} | {:error, String.t()}

  @doc "The pull requests GitHub associates with `commit`, as `GET commits/{sha}/pulls` answers."
  @callback commit_pulls(repository :: String.t(), commit :: String.t()) ::
              {:ok, [map()]} | {:error, String.t()}

  @doc ~s(The role `login` holds on `repository`: `"admin"`, `"write"`, `"read"` or another.)
  @callback permission(repository :: String.t(), login :: String.t()) ::
              {:ok, String.t()} | {:error, String.t()}

  @doc """
  Pull request `number` as `GET pulls/{number}` answers it, with `merged_by`, which the pull
  requests of a commit leave out.
  """
  @callback pull(repository :: String.t(), number :: pos_integer()) ::
              {:ok, map()} | {:error, String.t()}

  @doc """
  Every file pull request `number` changes, each with its `status` and `patch`, read page by
  page, or a refusal when GitHub lists more than it shows, 3000.
  """
  @callback pull_files(repository :: String.t(), number :: pos_integer()) ::
              {:ok, [map()]} | {:error, String.t()}
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

  @impl true
  def issue_state(repository, number) do
    case get("/repos/#{repository}/issues/#{number}") do
      {:ok, %{"state" => state}} when is_binary(state) -> {:ok, state}
      {:ok, _body} -> {:error, "GitHub's issue #{repository}##{number} has no state"}
      {:error, reason} -> {:error, "GitHub's issue #{repository}##{number} #{reason}"}
    end
  end

  @impl true
  def commit_pulls(repository, commit) do
    case get("/repos/#{repository}/commits/#{commit}/pulls") do
      {:ok, pulls} when is_list(pulls) -> {:ok, pulls}
      {:ok, _body} -> {:error, "GitHub's pull requests of #{commit} are not a list"}
      {:error, reason} -> {:error, "GitHub's pull requests of #{commit} #{reason}"}
    end
  end

  @impl true
  def permission(repository, login) do
    case get("/repos/#{repository}/collaborators/#{URI.encode_www_form(login)}/permission") do
      {:ok, %{"permission" => role}} when is_binary(role) -> {:ok, role}
      {:ok, _body} -> {:error, "GitHub's role of #{login} on #{repository} has no permission"}
      {:error, reason} -> {:error, "GitHub's role of #{login} on #{repository} #{reason}"}
    end
  end

  @impl true
  def pull(repository, number) do
    case get("/repos/#{repository}/pulls/#{number}") do
      {:ok, %{} = pull} -> {:ok, pull}
      {:ok, _body} -> {:error, "GitHub's pull request #{number} is not an object"}
      {:error, reason} -> {:error, "GitHub's pull request #{number} #{reason}"}
    end
  end

  # GitHub lists at most 3000 files of a pull request, 30 pages of 100; a release changes a few.
  @impl true
  def pull_files(repository, number), do: files_from(repository, number, 1, [])

  defp files_from(_repository, number, 31, _files),
    do: {:error, "pull request #{number} changes more than the 3000 files GitHub lists"}

  defp files_from(repository, number, page, files) do
    case get("/repos/#{repository}/pulls/#{number}/files?per_page=100&page=#{page}") do
      {:ok, more} when is_list(more) and length(more) == 100 ->
        files_from(repository, number, page + 1, files ++ more)

      {:ok, more} when is_list(more) ->
        {:ok, files ++ more}

      {:ok, _body} ->
        {:error, "GitHub's files of pull request #{number} are not a list"}

      {:error, reason} ->
        {:error, "GitHub's files of pull request #{number} #{reason}"}
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
