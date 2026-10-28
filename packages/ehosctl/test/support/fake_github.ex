defmodule Ehosctl.FakeGitHub do
  @moduledoc """
  A fake of GitHub's API for the tests of `versions`, `changelog` and the notice: each
  repository's releases, each release's assets, and its tags, on a local port (Bypass). An asset
  is answered at once, as GitHub's API may; the redirect it usually answers with is
  `Ehosctl.GitHubTest`'s.
  """

  @doc "Starts the fake, and returns it with the options that point `Ehosctl.GitHub` at it."
  @spec start() :: {Bypass.t(), keyword()}
  def start do
    bypass = Bypass.open()
    {bypass, [github_api: "http://localhost:#{bypass.port}", allow_http: true]}
  end

  @doc """
  Lists `releases` for `repository`, each `{tag, fields}`: `"assets"` a map from an asset's name
  to its content, `"body"` its description. Assets are numbered from `first_id`.
  """
  @spec releases(Bypass.t(), String.t(), [{String.t(), map()}], pos_integer()) :: :ok
  def releases(bypass, repository, releases, first_id \\ 1) do
    {listed, _id} =
      Enum.map_reduce(releases, first_id * 100, fn {tag, fields}, id ->
        assets = Map.get(fields, "assets", %{})

        listed = list_assets(bypass, repository, assets, id)

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

    Bypass.stub(bypass, "GET", "/repos/#{repository}/releases", fn conn ->
      json(conn, 200, listed)
    end)
  end

  @doc """
  Lists `tags` for `repository`, each `{name, commit}`, as GitHub's tags API does: the commit is
  the one an annotated tag points at too.
  """
  @spec tags(Bypass.t(), String.t(), [{String.t(), String.t()}]) :: :ok
  def tags(bypass, repository, tags) do
    listed =
      for {name, commit} <- tags,
          do: %{"name" => name, "commit" => %{"sha" => commit, "url" => "unused"}}

    Bypass.stub(bypass, "GET", "/repos/#{repository}/tags", &json(&1, 200, listed))
  end

  @doc "Answers every list of releases of `repository` with `status`."
  @spec refuse(Bypass.t(), String.t(), pos_integer()) :: :ok
  def refuse(bypass, repository, status) do
    Bypass.stub(bypass, "GET", "/repos/#{repository}/releases", fn conn ->
      json(conn, status, %{"message" => "Not Found"})
    end)
  end

  @doc "Answers GitHub's comparison of `base` with `head` in `repository`."
  @spec compare(Bypass.t(), String.t(), String.t(), String.t(), map()) :: :ok
  def compare(bypass, repository, base, head, answer) do
    Bypass.stub(bypass, "GET", "/repos/#{repository}/compare/#{base}...#{head}", fn conn ->
      json(conn, 200, answer)
    end)
  end

  defp list_assets(bypass, repository, assets, id) do
    for {{name, content}, index} <- Enum.with_index(assets) do
      asset_id = id + index
      stub_asset(bypass, repository, asset_id, content)
      %{"name" => name, "id" => asset_id}
    end
  end

  defp stub_asset(bypass, repository, asset_id, content) do
    Bypass.stub(
      bypass,
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
