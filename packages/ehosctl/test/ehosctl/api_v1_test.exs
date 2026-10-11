defmodule Ehosctl.ApiV1Test do
  # eh-os D-91 (ehos-tools#97): EHOS's API is at /api/v1, `GET /api/v1` says what the installation
  # is, and a command whose route the installation lacks says so rather than a bare 404.
  use Ehosctl.SignInCase

  alias Ehosctl.Api

  doctest Ehosctl.Api, only: [running: 1, route?: 3]

  @described %{
    "component" => "ehos",
    "version" => "0.5.0-dev",
    "commit" => "1a000cc4e50fd1e75558dfb1638c8b08286fe0bd",
    "produces" => ["ehos.api/v1", "ehos.credential/v1"],
    "accepts" => ["ehos.yaml/v1", "ehos.yaml/v2", "ehos.manifest/v2"],
    "requires" => %{"ehosctl" => ">= 0.3.0-dev"},
    "routes" => [
      %{"method" => "GET", "path" => "/api/v1/audit"},
      %{"method" => "PATCH", "path" => "/api/v1/people/:id"}
    ]
  }

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    :ok
  end

  defp installation(provider), do: {"local", %{"url" => provider.issuer}}

  # Phoenix's router answers a route it lacks with a 404 and no code of EHOS's.
  defp no_route(provider, method, path),
    do:
      FakeProvider.stub_api(provider, method, path, fn _ ->
        {404, %{"errors" => %{"detail" => "Not Found"}}}
      end)

  describe "describe/2" do
    test "reads what the installation says about itself, keeping only its fields",
         %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "GET", "/api/v1", fn _ ->
        {200, Map.put(@described, "extra", "dropped")}
      end)

      assert Api.describe(installation(provider), opts) == {:ok, @described}
    end

    test "an installation that answers 404 there predates it", %{provider: provider, opts: opts} do
      no_route(provider, "GET", "/api/v1")
      assert Api.describe(installation(provider), opts) == {:ok, :predates}
    end

    test "an answer of another shape is one ehosctl cannot read",
         %{provider: provider, opts: opts} do
      for broken <- [
            Map.delete(@described, "routes"),
            Map.put(@described, "version", "not a version"),
            Map.put(@described, "accepts", ["ehos.yaml/v1\e[2J"]),
            Map.put(@described, "requires", %{"ehosctl" => 3})
          ] do
        FakeProvider.stub_api(provider, "GET", "/api/v1", fn _ -> {200, broken} end)

        assert {:error, :failed, message} = Api.describe(installation(provider), opts)
        assert message =~ "cannot read"
      end
    end

    test "a refusal is an error of its kind", %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "GET", "/api/v1", fn _ -> {200, @described} end)
      FakeProvider.answer_api(provider, 401, %{"error" => "expired"})
      assert {:error, :not_signed_in, _} = Api.describe(installation(provider), opts)
    end
  end

  describe "a route the installation lacks" do
    test "is said to need a later EHOS, with the version it runs, and exits 1",
         %{provider: provider, opts: opts} do
      no_route(provider, "GET", "/api/v1/installation")
      FakeProvider.stub_api(provider, "GET", "/api/v1", fn _ -> {200, @described} end)

      {1, "", stderr} = ehosctl(["installation"], opts)
      assert stderr =~ "runs EHOS 0.5.0-dev (1a000cc), which has no `GET /api/v1/installation`"
      assert stderr =~ "The operator upgrades EHOS"
    end

    test "an installation without /api/v1 at all is said to be older than this ehosctl",
         %{provider: provider, opts: opts} do
      no_route(provider, "GET", "/api/v1/installation")
      no_route(provider, "GET", "/api/v1")

      {1, "", stderr} = ehosctl(["installation"], opts)
      assert stderr =~ "has no /api/v1, the API this ehosctl calls"
    end

    test "a route it lists keeps its 404, as does one when GET /api/v1 cannot be read",
         %{provider: provider, opts: opts} do
      no_route(provider, "GET", "/api/v1/installation")

      described = %{
        @described
        | "routes" => [%{"method" => "GET", "path" => "/api/v1/installation"}]
      }

      FakeProvider.stub_api(provider, "GET", "/api/v1", fn _ -> {200, described} end)
      {1, "", stderr} = ehosctl(["installation"], opts)
      assert stderr == "ehosctl: Not Found\n"

      FakeProvider.stub_api(provider, "GET", "/api/v1", fn _ -> {503, nil} end)
      {1, "", stderr} = ehosctl(["installation"], opts)
      assert stderr == "ehosctl: Not Found\n"
    end

    test "a 404 with EHOS's own code is its refusal, and GET /api/v1 is not asked",
         %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "GET", "/api/v1/people/:id", fn _ ->
        {404, %{"error" => "not_found", "message" => "That person no longer exists."}}
      end)

      {1, "", stderr} = ehosctl(["people", "show", "8b3e-grace"], opts)
      assert stderr =~ "That person no longer exists."
      assert FakeProvider.requests(provider, "GET /api/v1") == []
    end
  end
end
