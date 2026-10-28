defmodule Ehosctl.FakeGitHub do
  @moduledoc """
  A fake of GitHub's API for the tests of `versions`, `changelog` and the notice: each
  repository's releases, each release's assets, and its tags, at an address of its own
  (`Ehosctl.FakeHTTP`). An asset
  is answered at once, as GitHub's API may; the redirect it usually answers with is
  `Ehosctl.GitHubTest`'s.
  """

  @doc "Starts the fake, and returns it with the options that point `Ehosctl.GitHub` at it."
  @spec start() :: {Ehosctl.FakeHTTP.t(), keyword()}
  def start do
    github = Ehosctl.FakeHTTP.open()
    {github, [github_api: github.origin, allow_http: true]}
  end

  @doc """
  Lists `releases` for `repository`, each `{tag, fields}`: `"assets"` a map from an asset's name
  to its content, `"body"` its description. Assets are numbered from `first_id`.
  """
  @spec releases(Ehosctl.FakeHTTP.t(), String.t(), [{String.t(), map()}], pos_integer()) :: :ok
  def releases(github, repository, releases, first_id \\ 1) do
    {listed, _id} =
      Enum.map_reduce(releases, first_id * 100, fn {tag, fields}, id ->
        assets = Map.get(fields, "assets", %{})

        listed = list_assets(github, repository, assets, id)

        release = %{
          "tag_name" => tag,
          "draft" => false,
          "prerelease" => false,
          "html_url" => "https://github.com/#{repository}/releases/tag/#{tag}",
          "published_at" => Map.get(fields, "published_at", "2026-10-09T12:00:00Z"),
          "body" => Map.get(fields, "body", "Notes of #{tag}."),
          "assets" => listed
        }

        {release, id + 100}
      end)

    Ehosctl.FakeHTTP.stub(github, "GET", "/repos/#{repository}/releases", fn conn ->
      json(conn, 200, listed)
    end)
  end

  @doc """
  Lists `tags` for `repository`, each `{name, commit}`, as GitHub's tags API does: the commit is
  the one an annotated tag points at too.
  """
  @spec tags(Ehosctl.FakeHTTP.t(), String.t(), [{String.t(), String.t()}]) :: :ok
  def tags(github, repository, tags) do
    listed =
      for {name, commit} <- tags,
          do: %{"name" => name, "commit" => %{"sha" => commit, "url" => "unused"}}

    Ehosctl.FakeHTTP.stub(github, "GET", "/repos/#{repository}/tags", &json(&1, 200, listed))
  end

  @doc "Answers every list of releases of `repository` with `status`."
  @spec refuse(Ehosctl.FakeHTTP.t(), String.t(), pos_integer()) :: :ok
  def refuse(github, repository, status) do
    Ehosctl.FakeHTTP.stub(github, "GET", "/repos/#{repository}/releases", fn conn ->
      json(conn, status, %{"message" => "Not Found"})
    end)
  end

  @doc "Answers GitHub's comparison of `base` with `head` in `repository`."
  @spec compare(Ehosctl.FakeHTTP.t(), String.t(), String.t(), String.t(), map()) :: :ok
  def compare(github, repository, base, head, answer) do
    Ehosctl.FakeHTTP.stub(
      github,
      "GET",
      "/repos/#{repository}/compare/#{base}...#{head}",
      fn conn ->
        json(conn, 200, answer)
      end
    )
  end

  defp list_assets(github, repository, assets, id) do
    for {{name, content}, index} <- Enum.with_index(assets) do
      asset_id = id + index
      stub_asset(github, repository, asset_id, content)
      %{"name" => name, "id" => asset_id}
    end
  end

  defp stub_asset(github, repository, asset_id, content) do
    Ehosctl.FakeHTTP.stub(
      github,
      "GET",
      "/repos/#{repository}/releases/assets/#{asset_id}",
      fn conn ->
        content = if is_binary(content), do: content, else: JSON.encode!(content)
        Plug.Conn.resp(conn, 200, content)
      end
    )
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, JSON.encode!(body))
  end
end
