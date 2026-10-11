defmodule Ehosctl.GitHubTest do
  # eh-os D-91 (ehos-tools#97): what exists and what changed comes from GitHub's releases, read
  # with the developer's token, which goes to GitHub's API and nowhere else.
  use ExUnit.Case, async: true

  alias Ehosctl.GitHub

  doctest GitHub

  @release_json %{
    "schema" => "ehos.release/v1",
    "component" => "eh_os_contract",
    "version" => "0.3.0",
    "commit" => "3304f355eb5d73058fa8fcf61813f9c0547f9fc6",
    "produces" => ["ehos.manifest/v2", "ehos.manifest/v3", "eh_os_contract.api/v1"],
    "accepts" => ["ehos.credential/v1"],
    "requires" => %{}
  }

  setup do
    api = Bypass.open()
    storage = Bypass.open()

    opts = [
      github_api: "http://localhost:#{api.port}",
      allow_http: true,
      env: %{"GITHUB_TOKEN" => "ghp_test"},
      timeout: 5_000
    ]

    %{api: api, storage: storage, opts: opts}
  end

  defp release(tag, fields \\ %{}) do
    Map.merge(
      %{
        "tag_name" => tag,
        "draft" => false,
        "prerelease" => false,
        "html_url" => "https://github.com/EmpoweredHouse/ehos-tools/releases/tag/#{tag}",
        "published_at" => "2026-10-09T12:00:00Z",
        "body" => "Notes of #{tag}",
        "assets" => []
      },
      fields
    )
  end

  defp list(bypass, repository, releases) do
    Bypass.stub(bypass, "GET", "/repos/#{repository}/releases", &json(&1, 200, releases))
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, JSON.encode!(body))
  end

  describe "releases/2" do
    test "lists a component's releases, newest by version, leaving out drafts, pre-releases " <>
           "and the other components' tags",
         %{api: api, opts: opts} do
      list(api, "EmpoweredHouse/ehos-tools", [
        release("v0.1.1"),
        release("ehos_app-v0.7.0"),
        release("v0.10.0"),
        release("v0.2.0"),
        release("v0.3.0", %{"draft" => true}),
        release("v0.4.0", %{"prerelease" => true}),
        release("v0.5.0-rc.1"),
        release("vnext")
      ])

      assert {:ok, releases} = GitHub.releases("ehosctl", opts)
      assert Enum.map(releases, & &1.version) == ["0.10.0", "0.2.0", "0.1.1"]
      assert {:ok, [app]} = GitHub.releases("ehos_app", opts)
      assert app.version == "0.7.0"
      assert app.tag == "ehos_app-v0.7.0"
      assert {:ok, []} = GitHub.releases("ehos_design", opts)
    end

    test "follows the next page on the API's own origin, and no other",
         %{api: api, opts: opts} do
      Bypass.stub(api, "GET", "/repos/EmpoweredHouse/eh-os/releases", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case conn.query_params["page"] do
          nil ->
            conn
            |> Plug.Conn.put_resp_header(
              "link",
              ~s(<#{opts[:github_api]}/repos/EmpoweredHouse/eh-os/releases?page=2>; rel="next")
            )
            |> json(200, [release("v0.4.0")])

          "2" ->
            conn
            |> Plug.Conn.put_resp_header(
              "link",
              ~s(<https://elsewhere.example/releases?page=3>; rel="next")
            )
            |> json(200, [release("v0.5.0")])
        end
      end)

      assert {:ok, releases} = GitHub.releases("ehos", opts)
      assert Enum.map(releases, & &1.version) == ["0.5.0", "0.4.0"]
    end

    test "sends the token to the API, MISE_GITHUB_TOKEN before GITHUB_TOKEN",
         %{api: api, opts: opts} do
      test = self()

      Bypass.stub(api, "GET", "/repos/EmpoweredHouse/eh-os/releases", fn conn ->
        send(test, {:authorization, Plug.Conn.get_req_header(conn, "authorization")})
        json(conn, 200, [])
      end)

      env = %{"GITHUB_TOKEN" => "ghp_test", "MISE_GITHUB_TOKEN" => "ghp_mise"}
      assert {:ok, []} = GitHub.releases("ehos", Keyword.put(opts, :env, env))
      assert_received {:authorization, ["Bearer ghp_mise"]}

      assert {:ok, []} = GitHub.releases("ehos", Keyword.put(opts, :env, %{}))
      assert_received {:authorization, []}
    end

    test "without a token, a repository GitHub does not show is said to need one",
         %{api: api, opts: opts} do
      for status <- [404, 401] do
        Bypass.stub(api, "GET", "/repos/EmpoweredHouse/eh-os/releases", fn conn ->
          json(conn, status, %{"message" => "Not Found"})
        end)

        assert {:error, :failed, message} =
                 GitHub.releases("ehos", Keyword.put(opts, :env, %{}))

        assert message =~ "without a token"
        assert message =~ "MISE_GITHUB_TOKEN or GITHUB_TOKEN"
      end
    end

    test "with a token, a 401 or 404 names the token's variable", %{api: api, opts: opts} do
      for {status, said} <- [{401, "refused the token in GITHUB_TOKEN"}, {404, "cannot read"}] do
        Bypass.stub(api, "GET", "/repos/EmpoweredHouse/eh-os/releases", fn conn ->
          json(conn, status, %{"message" => "Bad credentials"})
        end)

        assert {:error, :failed, message} = GitHub.releases("ehos", opts)
        assert message =~ said
      end
    end

    test "a rate limit used up says so", %{api: api, opts: opts} do
      Bypass.stub(api, "GET", "/repos/EmpoweredHouse/eh-os/releases", fn conn ->
        conn |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0") |> json(403, %{})
      end)

      assert {:error, :failed, message} = GitHub.releases("ehos", opts)
      assert message =~ "rate limit is used up"
    end

    test "offline is an error of kind :unreachable", %{api: api, opts: opts} do
      Bypass.down(api)
      assert {:error, :unreachable, message} = GitHub.releases("ehos", opts)
      assert message =~ "did not answer"
    end

    test "an answer larger than it reads is refused, not read whole", %{api: api, opts: opts} do
      big = String.duplicate("x", 17 * 1024 * 1024)

      Bypass.stub(api, "GET", "/repos/EmpoweredHouse/eh-os/releases", fn conn ->
        json(conn, 200, [release("v0.1.0", %{"body" => big})])
      end)

      assert {:error, :failed, message} = GitHub.releases("ehos", opts)
      assert message =~ "more than ehosctl reads"
    end
  end

  describe "assets" do
    setup %{api: api, opts: opts} do
      list(api, "EmpoweredHouse/eh-os-contract", [
        release("v0.3.0", %{
          "body" => "In notes.md, attached.",
          "assets" => [
            %{"name" => "release.json", "id" => 11},
            %{"name" => "notes.md", "id" => 12}
          ]
        }),
        release("v0.2.1", %{"body" => "## eh_os_contract 0.2.1\n\n### Fixed\n\n- A fix."})
      ])

      {:ok, releases} = GitHub.releases("eh_os_contract", opts)
      %{releases: releases}
    end

    # The API answers an asset with a redirect to where it is kept, on another host.
    defp redirect(api, storage, id, path) do
      Bypass.stub(
        api,
        "GET",
        "/repos/EmpoweredHouse/eh-os-contract/releases/assets/#{id}",
        fn conn ->
          conn
          |> Plug.Conn.put_resp_header("location", "http://127.0.0.1:#{storage.port}#{path}")
          |> Plug.Conn.resp(302, "")
        end
      )
    end

    test "release.json is downloaded through the API's redirect, which carries no token",
         %{api: api, storage: storage, opts: opts, releases: [newest, older]} do
      test = self()
      redirect(api, storage, 11, "/signed/release.json")

      Bypass.expect_once(storage, "GET", "/signed/release.json", fn conn ->
        send(test, {:storage, Plug.Conn.get_req_header(conn, "authorization")})
        Plug.Conn.resp(conn, 200, JSON.encode!(@release_json))
      end)

      assert GitHub.release_json(newest, opts) == {:ok, @release_json}
      assert_received {:storage, []}

      assert GitHub.release_json(older, opts) == {:ok, nil}
    end

    test "the token goes to the API when it asks for the asset",
         %{api: api, storage: storage, opts: opts, releases: [newest, _older]} do
      test = self()

      Bypass.stub(
        api,
        "GET",
        "/repos/EmpoweredHouse/eh-os-contract/releases/assets/11",
        fn conn ->
          send(test, {:api, Plug.Conn.get_req_header(conn, "authorization")})

          conn
          |> Plug.Conn.put_resp_header("location", "http://127.0.0.1:#{storage.port}/r")
          |> Plug.Conn.resp(302, "")
        end
      )

      Bypass.stub(storage, "GET", "/r", &Plug.Conn.resp(&1, 200, JSON.encode!(@release_json)))

      assert {:ok, _} = GitHub.release_json(newest, opts)
      assert_received {:api, ["Bearer ghp_test"]}
    end

    test "a redirect to plain http is refused outside the tests",
         %{api: api, storage: storage, opts: opts, releases: [newest, _older]} do
      redirect(api, storage, 11, "/signed/release.json")

      assert {:error, :failed, message} =
               GitHub.release_json(newest, Keyword.delete(opts, :allow_http))

      assert message =~ "elsewhere than https"
    end

    test "a release.json that is not that release's is refused, and says why",
         %{api: api, storage: storage, opts: opts, releases: [newest, _older]} do
      redirect(api, storage, 11, "/r")

      for {broken, why} <- [
            {Map.put(@release_json, "schema", "ehos.release/v2"), "schema"},
            {Map.put(@release_json, "component", "ehosctl"), "names ehosctl"},
            {Map.put(@release_json, "version", "0.2.1"), "names version 0.2.1"},
            {Map.delete(@release_json, "version"), "names version nothing"}
          ] do
        Bypass.stub(storage, "GET", "/r", &Plug.Conn.resp(&1, 200, JSON.encode!(broken)))
        assert {:error, :failed, message} = GitHub.release_json(newest, opts)
        assert message =~ "The release.json of v0.3.0"
        assert message =~ why
      end
    end

    test "a release.json that is not a JSON object is an error",
         %{api: api, storage: storage, opts: opts, releases: [newest, _older]} do
      redirect(api, storage, 11, "/r")
      Bypass.stub(storage, "GET", "/r", &Plug.Conn.resp(&1, 200, "[1]"))
      assert {:error, :failed, _} = GitHub.release_json(newest, opts)
    end

    test "notes are the attached notes.md when there is one, else the description",
         %{api: api, storage: storage, opts: opts, releases: [newest, older]} do
      redirect(api, storage, 12, "/notes.md")
      notes = "## eh_os_contract 0.3.0\n\n### Added\n\n- " <> String.duplicate("y", 160_000)
      Bypass.stub(storage, "GET", "/notes.md", &Plug.Conn.resp(&1, 200, notes))

      assert GitHub.notes(newest, opts) == {:ok, notes}

      assert GitHub.notes(older, opts) ==
               {:ok, "## eh_os_contract 0.2.1\n\n### Fixed\n\n- A fix."}
    end
  end

  describe "compare/4" do
    test "says how far one commit is from another", %{api: api, opts: opts} do
      Bypass.stub(
        api,
        "GET",
        "/repos/EmpoweredHouse/eh-os-contract/compare/aaaaaaa...bbbbbbb",
        fn conn ->
          json(conn, 200, %{"status" => "behind", "ahead_by" => 0, "behind_by" => 738})
        end
      )

      assert GitHub.compare("eh_os_contract", "aaaaaaa", "bbbbbbb", opts) ==
               {:ok, %{status: "behind", ahead_by: 0, behind_by: 738}}
    end

    test "refuses anything but two commits" do
      assert {:error, :invalid, _} = GitHub.compare("eh_os_contract", "main", "../x", [])
    end
  end
end
