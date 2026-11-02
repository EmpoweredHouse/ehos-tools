defmodule Ehosctl.GitHubTest do
  # eh-os D-91 (ehos-tools#97): what exists and what changed comes from GitHub's releases, read
  # with the developer's token, which goes to GitHub's API and nowhere else.
  use Ehosctl.Case, async: true

  alias Ehosctl.FakeGitHub
  alias Ehosctl.FakeHTTP
  alias Ehosctl.GitHub

  doctest GitHub

  @env %{"GITHUB_TOKEN" => "ghp_test"}

  @release_json %{
    "schema" => "ehos.release/v1",
    "component" => "eh_os_contract",
    "version" => "0.3.0",
    "commit" => "3304f355eb5d73058fa8fcf61813f9c0547f9fc6",
    "produces" => ["ehos.manifest/v2", "ehos.manifest/v3", "eh_os_contract.api/v1"],
    "accepts" => ["ehos.credential/v1"],
    "requires" => %{}
  }

  @rate_limit "GitHub's rate limit is used up (HTTP 403); try again later."

  setup do
    api = FakeGitHub.start()
    # Where GitHub keeps an asset, on another host than its API.
    storage = FakeHTTP.open(origin: "https://release-assets.githubusercontent.com")
    opts = [timeout: 5_000]

    stub_env(@env)

    %{api: api, storage: storage, opts: opts}
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

      assert GitHub.releases("ehosctl", opts) ==
               {:ok,
                [
                  listed("ehosctl", "EmpoweredHouse/ehos-tools", "v0.10.0", "0.10.0"),
                  listed("ehosctl", "EmpoweredHouse/ehos-tools", "v0.2.0", "0.2.0"),
                  listed("ehosctl", "EmpoweredHouse/ehos-tools", "v0.1.1", "0.1.1")
                ]}

      assert GitHub.releases("ehos_app", opts) ==
               {:ok,
                [listed("ehos_app", "EmpoweredHouse/ehos-tools", "ehos_app-v0.7.0", "0.7.0")]}

      assert GitHub.releases("ehos_design", opts) == {:ok, []}
    end

    test "follows the next page on the API's own origin, and no other",
         %{api: api, opts: opts} do
      FakeHTTP.stub(api, "GET", "/repos/EmpoweredHouse/eh-os/releases", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case conn.query_params["page"] do
          nil ->
            conn
            |> Plug.Conn.put_resp_header(
              "link",
              ~s(<#{api.origin}/repos/EmpoweredHouse/eh-os/releases?page=2>; rel="next")
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

      assert GitHub.releases("ehos", opts) ==
               {:ok,
                [
                  listed("ehos", "EmpoweredHouse/eh-os", "v0.5.0", "0.5.0"),
                  listed("ehos", "EmpoweredHouse/eh-os", "v0.4.0", "0.4.0")
                ]}
    end

    test "trusts the system's CAs alone, so neither EHOSCTL_CA_FILE nor a kept CA is used",
         %{opts: opts} do
      stub_env(Map.put(@env, "EHOSCTL_CA_FILE", "/etc/ehos/local-ca.crt"))
      opts = Keyword.put(opts, :ca, {"staging", "no certificate"})
      mock_get_without_ca([release("v0.1.0")])

      assert GitHub.releases("ehosctl", opts) ==
               {:ok, [listed("ehosctl", "EmpoweredHouse/ehos-tools", "v0.1.0", "0.1.0")]}
    end

    test "sends the token to the API, MISE_GITHUB_TOKEN before GITHUB_TOKEN",
         %{api: api, opts: opts} do
      test = self()

      FakeHTTP.stub(api, "GET", "/repos/EmpoweredHouse/eh-os/releases", fn conn ->
        send(test, {:authorization, Plug.Conn.get_req_header(conn, "authorization")})
        json(conn, 200, [])
      end)

      env = %{"GITHUB_TOKEN" => "ghp_test", "MISE_GITHUB_TOKEN" => "ghp_mise"}
      stub_env(env)
      assert GitHub.releases("ehos", opts) == {:ok, []}
      assert_received {:authorization, ["Bearer ghp_mise"]}

      stub_env(%{})
      assert GitHub.releases("ehos", opts) == {:ok, []}
      assert_received {:authorization, []}
    end

    test "a list longer than it reads says it was cut", %{api: api, opts: opts} do
      FakeHTTP.stub(api, "GET", "/repos/EmpoweredHouse/eh-os/releases", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        page = String.to_integer(conn.query_params["page"] || "1")

        conn
        |> Plug.Conn.put_resp_header(
          "link",
          ~s(<#{api.origin}/repos/EmpoweredHouse/eh-os/releases?page=#{page + 1}>; rel="next")
        )
        |> json(200, [release("v0.#{page}.0")])
      end)

      assert GitHub.list("EmpoweredHouse/eh-os", opts) ==
               {:ok,
                for page <- 1..10 do
                  tag = "v0.#{page}.0"

                  %{
                    tag: tag,
                    body: "Notes of #{tag}",
                    url: "https://github.com/EmpoweredHouse/ehos-tools/releases/tag/#{tag}",
                    published_at: "2026-10-09T12:00:00Z",
                    assets: %{}
                  }
                end, :cut}
    end

    test "without a token, a repository GitHub does not show is said to need one",
         %{api: api, opts: opts} do
      for status <- [404, 401] do
        FakeHTTP.stub(api, "GET", "/repos/EmpoweredHouse/eh-os/releases", fn conn ->
          json(conn, status, %{"message" => "Not Found"})
        end)

        stub_env(%{})

        assert GitHub.releases("ehos", opts) ==
                 {:error, :failed,
                  "GitHub does not show EHOS's releases without a token, since their " <>
                    "repositories are private. Set MISE_GITHUB_TOKEN or GITHUB_TOKEN, for " <>
                    "example to `gh auth token`."}
      end
    end

    test "with a token, a 401 or 404 names the token's variable", %{api: api, opts: opts} do
      for {status, said} <- [
            {401,
             "GitHub refused the token in GITHUB_TOKEN (HTTP 401). The token is possibly " <>
               "expired. Set GITHUB_TOKEN to a valid token."},
            {404,
             "GitHub answered 404 for EmpoweredHouse/eh-os. The token in GITHUB_TOKEN " <>
               "cannot read this repository. Use a token that can read it."}
          ] do
        FakeHTTP.stub(api, "GET", "/repos/EmpoweredHouse/eh-os/releases", fn conn ->
          json(conn, status, %{"message" => "Bad credentials"})
        end)

        assert GitHub.releases("ehos", opts) == {:error, :failed, said}
      end
    end

    test "without a token, a rate limit used up is said as one, not as a private repository",
         %{api: api, opts: opts} do
      rate_limit_used_up(api, "EmpoweredHouse/eh-os/releases")

      stub_env(%{})
      assert GitHub.releases("ehos", opts) == {:error, :failed, @rate_limit}
    end

    test "a rate limit used up says so", %{api: api, opts: opts} do
      rate_limit_used_up(api, "EmpoweredHouse/eh-os/releases")

      assert GitHub.releases("ehos", opts) == {:error, :failed, @rate_limit}
    end

    test "offline is an error of kind :unreachable", %{api: api, opts: opts} do
      FakeHTTP.down(api)

      assert GitHub.releases("ehos", opts) ==
               {:error, :unreachable, "https://api.github.com did not answer."}
    end

    test "an answer larger than it reads is refused, not read whole", %{api: api, opts: opts} do
      big = String.duplicate("x", 17 * 1024 * 1024)

      FakeHTTP.stub(api, "GET", "/repos/EmpoweredHouse/eh-os/releases", fn conn ->
        json(conn, 200, [release("v0.1.0", %{"body" => big})])
      end)

      assert GitHub.releases("ehos", opts) ==
               {:error, :failed,
                "https://api.github.com answered with more than 16777216 bytes, more than " <>
                  "ehosctl reads from it."}
    end
  end

  describe "release_json/2 and notes/2" do
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

    test "release.json is downloaded through the API's redirect, which carries no token",
         %{api: api, storage: storage, opts: opts, releases: [newest, older]} do
      test = self()
      redirect(api, storage, 11, "/signed/release.json")

      FakeHTTP.expect_once(storage, "GET", "/signed/release.json", fn conn ->
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

      FakeHTTP.stub(
        api,
        "GET",
        "/repos/EmpoweredHouse/eh-os-contract/releases/assets/11",
        fn conn ->
          send(test, {:api, Plug.Conn.get_req_header(conn, "authorization")})

          conn
          |> Plug.Conn.put_resp_header("location", storage.origin <> "/r")
          |> Plug.Conn.resp(302, "")
        end
      )

      FakeHTTP.stub(storage, "GET", "/r", &Plug.Conn.resp(&1, 200, JSON.encode!(@release_json)))

      assert GitHub.release_json(newest, opts) == {:ok, @release_json}
      assert_received {:api, ["Bearer ghp_test"]}
    end

    test "notes are the attached notes.md when there is one, else the description",
         %{api: api, storage: storage, opts: opts, releases: [newest, older]} do
      redirect(api, storage, 12, "/notes.md")
      notes = "## eh_os_contract 0.3.0\n\n### Added\n\n- " <> String.duplicate("y", 160_000)
      FakeHTTP.stub(storage, "GET", "/notes.md", &Plug.Conn.resp(&1, 200, notes))

      assert GitHub.notes(newest, opts) == {:ok, notes}

      assert GitHub.notes(older, opts) ==
               {:ok, "## eh_os_contract 0.2.1\n\n### Fixed\n\n- A fix."}
    end

    test "a redirect to plain http is refused",
         %{api: api, opts: opts, releases: [newest, _older]} do
      plain = FakeHTTP.open(origin: "http://release-assets.githubusercontent.com")
      redirect(api, plain, 11, "/signed/release.json")

      assert GitHub.release_json(newest, opts) ==
               {:error, :failed,
                "GitHub sent the download of an asset to an address without https. ehosctl " <>
                  "does not follow it."}
    end

    test "a release.json that is not that release's is refused, and says why",
         %{api: api, storage: storage, opts: opts, releases: [newest, _older]} do
      redirect(api, storage, 11, "/r")

      for {broken, why} <- [
            {Map.put(@release_json, "schema", "ehos.release/v2"),
             "has the schema ehos.release/v2, not ehos.release/v1"},
            {Map.put(@release_json, "component", "ehosctl"), "names ehosctl, not eh_os_contract"},
            {Map.put(@release_json, "version", "0.2.1"), "names version 0.2.1, not 0.3.0"},
            {Map.delete(@release_json, "version"), "names version nothing, not 0.3.0"}
          ] do
        FakeHTTP.stub(storage, "GET", "/r", &Plug.Conn.resp(&1, 200, JSON.encode!(broken)))

        assert GitHub.release_json(newest, opts) ==
                 {:error, :failed, "The release.json of v0.3.0 #{why}."}
      end
    end

    test "a release.json that is not a JSON object is an error",
         %{api: api, storage: storage, opts: opts, releases: [newest, _older]} do
      redirect(api, storage, 11, "/r")
      FakeHTTP.stub(storage, "GET", "/r", &Plug.Conn.resp(&1, 200, "[1]"))

      assert GitHub.release_json(newest, opts) ==
               {:error, :failed, "The release.json of v0.3.0 is not a JSON object."}
    end
  end

  describe "tags/3" do
    test "names the tag of each wanted commit, the newest of several, leaving out " <>
           "pre-releases, the other components' tags and what a terminal cannot print",
         %{api: api, opts: opts} do
      test = self()
      a = String.duplicate("a", 40)
      b = String.duplicate("b", 40)
      c = String.duplicate("c", 40)

      FakeHTTP.stub(api, "GET", "/repos/EmpoweredHouse/ehos-tools/tags", fn conn ->
        send(test, {:authorization, Plug.Conn.get_req_header(conn, "authorization")})

        json(conn, 200, [
          tag("ehos_app-v0.5.0", a),
          tag("ehos_app-v0.5.1", a),
          tag("ehos_app-v0.10.0", b),
          tag("ehos_app-v0.6.0-rc.1", c),
          tag("v0.3.0", c),
          tag("ehos_design-v0.2.0", b),
          tag("ehos_app-v0.7.0\e[2J", c),
          tag("ehos_app-v0.8.0", "abc1234"),
          %{"name" => "ehos_app-v0.9.0"}
        ])
      end)

      wanted = [{"ehos_app", a}, {"ehos_app", c}, {"ehos_design", b}]

      assert GitHub.tags("EmpoweredHouse/ehos-tools", wanted, opts) ==
               {:ok,
                %{
                  {"ehos_app", a} => %{
                    component: "ehos_app",
                    version: "0.5.1",
                    tag: "ehos_app-v0.5.1",
                    commit: a,
                    repository: "EmpoweredHouse/ehos-tools"
                  },
                  {"ehos_design", b} => %{
                    component: "ehos_design",
                    version: "0.2.0",
                    tag: "ehos_design-v0.2.0",
                    commit: b,
                    repository: "EmpoweredHouse/ehos-tools"
                  }
                }, :whole}

      assert_received {:authorization, ["Bearer ghp_test"]}
    end

    test "stops at the page that names every wanted commit", %{api: api, opts: opts} do
      d = String.duplicate("d", 40)
      endless_tags(api, self(), d)

      assert GitHub.tags("EmpoweredHouse/eh-os-contract", [{"eh_os_contract", d}], opts) ==
               {:ok,
                %{
                  {"eh_os_contract", d} => %{
                    component: "eh_os_contract",
                    version: "0.1.0",
                    tag: "v0.1.0",
                    commit: d,
                    repository: "EmpoweredHouse/eh-os-contract"
                  }
                }, :whole}

      assert_received {:page, 1}
      refute_received {:page, 2}
    end

    test "a commit no tag names reads every page it may, and says the list was cut",
         %{api: api, opts: opts} do
      endless_tags(api, self(), String.duplicate("d", 40))
      wanted = [{"eh_os_contract", String.duplicate("e", 40)}]

      assert GitHub.tags("EmpoweredHouse/eh-os-contract", wanted, opts) == {:ok, %{}, :cut}
      assert_received {:page, 10}
      refute_received {:page, 11}
    end

    test "refuses an answer larger than it reads", %{api: api, opts: opts} do
      FakeHTTP.stub(api, "GET", "/repos/EmpoweredHouse/eh-os-contract/tags", fn conn ->
        json(conn, 200, [tag(String.duplicate("x", 2 * 1024 * 1024), String.duplicate("c", 40))])
      end)

      assert GitHub.tags("EmpoweredHouse/eh-os-contract", [{"eh_os_contract", "c"}], opts) ==
               {:error, :failed,
                "https://api.github.com answered with more than 1048576 bytes, more than " <>
                  "ehosctl reads from it."}
    end

    test "a refusal says why, as for releases", %{api: api, opts: opts} do
      rate_limit_used_up(api, "EmpoweredHouse/ehos-tools/tags")

      assert GitHub.tags("EmpoweredHouse/ehos-tools", [{"ehos_app", "a"}], opts) ==
               {:error, :failed, @rate_limit}
    end
  end

  describe "compare/4" do
    test "says how far one commit is from another", %{api: api, opts: opts} do
      FakeHTTP.stub(
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
      assert GitHub.compare("eh_os_contract", "main", "../x", []) ==
               {:error, :invalid, "ehosctl can compare only two commits, each named by its SHA."}
    end
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

  # A release `release/2` builds, as `GitHub.releases/2` reads it.
  defp listed(component, repository, tag, version) do
    %{
      tag: tag,
      version: version,
      body: "Notes of #{tag}",
      url: "https://github.com/EmpoweredHouse/ehos-tools/releases/tag/#{tag}",
      published_at: "2026-10-09T12:00:00Z",
      repository: repository,
      component: component,
      assets: %{}
    }
  end

  defp tag(name, commit), do: %{"name" => name, "commit" => %{"sha" => commit}}

  defp list(api, repository, releases) do
    FakeHTTP.stub(api, "GET", "/repos/#{repository}/releases", &json(&1, 200, releases))
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, JSON.encode!(body))
  end

  # The API answers an asset with a redirect to where it is kept, on another host.
  defp redirect(api, storage, id, path) do
    FakeHTTP.stub(
      api,
      "GET",
      "/repos/EmpoweredHouse/eh-os-contract/releases/assets/#{id}",
      fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", storage.origin <> path)
        |> Plug.Conn.resp(302, "")
      end
    )
  end

  # Pages of tags that never end: page N holds one tag, `v0.N.0`, naming `commit`.
  defp endless_tags(api, test, commit) do
    FakeHTTP.stub(api, "GET", "/repos/EmpoweredHouse/eh-os-contract/tags", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      page = String.to_integer(conn.query_params["page"] || "1")
      send(test, {:page, page})

      conn
      |> Plug.Conn.put_resp_header(
        "link",
        ~s(<#{api.origin}/repos/EmpoweredHouse/eh-os-contract/tags?page=#{page + 1}>; rel="next")
      )
      |> json(200, [tag("v0.#{page}.0", commit)])
    end)
  end

  defp rate_limit_used_up(api, path) do
    FakeHTTP.stub(api, "GET", "/repos/" <> path, fn conn ->
      conn |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0") |> json(403, %{})
    end)
  end

  # GitHub's list of ehosctl's releases, asked for with the system's CAs alone: no CA, and not as
  # an installation.
  defp mock_get_without_ca(releases) do
    user_agent = "ehosctl/#{Ehosctl.version()}"

    expect(Ehosctl.HTTPMock, :get, fn
      "https://api.github.com/repos/EmpoweredHouse/ehos-tools/releases?per_page=100",
      [
        {"accept", "application/vnd.github+json"},
        {"user-agent", ^user_agent},
        {"authorization", "Bearer ghp_test"},
        {"x-github-api-version", "2022-11-28"}
      ],
      [timeout: 5000, max_bytes: 16_777_216, installation?: false] ->
        {:ok, %{status: 200, headers: %{}, body: JSON.encode!(releases)}}
    end)
  end
end
