defmodule Ehosctl.VerifyServiceTest do
  # `ehosctl verify` in a utility service's repository, which holds ehos.yaml, a Dockerfile and no
  # Elixir (ehos-tools#917, eh-os D-175): the file checked, the bundle written, then EHOS asked
  # when an installation is chosen. Not async, through `Ehosctl.SignInCase`.
  use Ehosctl.SignInCase

  alias Ehosctl.Bundle

  @ehos_yaml """
  schema: ehos.yaml/v8
  kind: service
  application: invoice-pdf
  serves:
    - name: http
      port: 8080
  health:
    port: 8081
    ready: /ready
    live: /live
  """

  # What eh-os's `EhosYaml.service_manifest/1` writes from the same file (ehos-tools#917).
  @manifest ~s({"application":"invoice-pdf","ehos_yaml":"ehos.yaml/v8","health":{"live":"/live","port":8081,"ready":"/ready"},"kind":"service","schema":"ehos.manifest/v9","serves":[{"name":"http","port":8080}]})

  @found "ehos.yaml describes the utility service invoice-pdf. ehosctl checked it against " <>
           "ehos.yaml/v8 and found no error.\n" <>
           "The bundle is in _build/ehos.bundle. To register it with its image, run " <>
           "`ehosctl builds register _build/ehos.bundle --image <image>`.\n"

  @no_installation "EHOS did not check ehos.yaml and the application manifest: no " <>
                     "installation is chosen. To have this check, run `ehosctl login`.\n"

  setup %{tmp_dir: tmp_dir, opts: opts} do
    service = Path.join(tmp_dir, "invoice-pdf")
    File.mkdir_p!(service)
    File.write!(Path.join(service, "Dockerfile"), "FROM scratch\n")
    File.write!(Path.join(service, "ehos.yaml"), @ehos_yaml)
    %{service: service, opts: Keyword.put(opts, :dir, service)}
  end

  describe "verify, in a utility service's directory" do
    test "writes the bundle of the manifest EHOS would write, and runs nothing",
         %{service: service, opts: opts} do
      assert ehosctl(["verify"], opts) == {0, @found <> @no_installation, ""}

      bundle = Path.join(service, "_build/ehos.bundle")
      assert File.read!(Path.join(bundle, "ehos.manifest.json")) == @manifest
      assert File.ls!(bundle) |> Enum.sort() == ["bundle.json", "ehos.manifest.json"]

      assert {:ok, %{manifest: @manifest, graphs: [], application: "invoice-pdf"}} =
               Bundle.read(bundle)
    end

    test "replaces the bundle an earlier run left", %{service: service, opts: opts} do
      stale = Path.join(service, "_build/ehos.bundle/graph/removed.json")
      File.mkdir_p!(Path.dirname(stale))
      File.write!(stale, "{}")

      {0, _stdout, ""} = ehosctl(["verify"], opts)

      refute File.exists?(stale)
    end

    test "refuses each key a utility service may not give, with EHOS's reason, and writes no " <>
           "bundle",
         %{service: service, opts: opts} do
      File.write!(Path.join(service, "ehos.yaml"), """
      schema: ehos.yaml/v8
      kind: service
      application: invoice-pdf
      serves:
        - name: http
          port: 8080
          public: true
      health: {port: 8081, ready: /ready, live: /live}
      needs:
        database: {engine: postgres}
        people: read
        mail: {level: internal}
        services:
          - name: other
      sign_in: {applications: []}
      """)

      assert ehosctl(["verify"], opts) ==
               {2, "",
                """
                ehosctl: ehosctl refuses ehos.yaml:
                  - line 7, serves[0].public: must not be true for a utility service: only the applications of its environment reach it, each with a service agreement
                  - line 10, needs.database: is not for a utility service, which keeps no data of its own: remove it
                  - line 11, needs.people: is not for a utility service, which does not read the people directory: remove it
                  - line 12, needs.mail: is not for a utility service, which sends no mail through EHOS: remove it
                  - line 13, needs.services: is not for a utility service, which calls no other utility service: remove it
                  - line 15, sign_in: is not for a utility service, which signs nobody in: remove it
                ehosctl wrote no bundle.
                """}

      refute File.exists?(Path.join(service, "_build/ehos.bundle"))
    end

    test "refuses a utility service with no name", %{service: service, opts: opts} do
      File.write!(Path.join(service, "ehos.yaml"), """
      schema: ehos.yaml/v8
      kind: service
      health: {port: 8081, ready: /ready, live: /live}
      """)

      assert ehosctl(["verify"], opts) ==
               {2, "",
                "ehosctl: ehosctl refuses ehos.yaml:\n" <>
                  "  - line 1, application: is required for a utility service, which has no " <>
                  "contract to take its name from: name the service here\n" <>
                  "ehosctl wrote no bundle.\n"}
    end

    test "refuses an application's file, which has no mix.exs beside it",
         %{service: service, opts: opts} do
      File.write!(Path.join(service, "ehos.yaml"), """
      schema: ehos.yaml/v7
      health: {port: 8081, ready: /ready, live: /live}
      """)

      assert ehosctl(["verify"], opts) ==
               {2, "",
                "ehosctl: ehosctl refuses ehos.yaml:\n" <>
                  "  - line 1, schema: is ehos.yaml/v7, and ehosctl reads a utility service's " <>
                  "file in ehos.yaml/v8, the first version that says kind: service\n" <>
                  "ehosctl wrote no bundle.\n"}
    end

    test "refuses a link where the bundle goes", %{service: service, opts: opts, tmp_dir: tmp} do
      File.mkdir_p!(Path.join(service, "_build"))
      File.ln_s!(tmp, Path.join(service, "_build/ehos.bundle"))

      assert ehosctl(["verify"], opts) ==
               {2, "", "ehosctl: _build/ehos.bundle is not a directory (symlink).\n"}
    end
  end

  describe "verify, in a utility service's directory, signed in" do
    setup %{provider: provider, opts: opts} do
      login!(provider, opts)
      accept_both(provider)
      :ok
    end

    test "asks EHOS to check ehos.yaml and the manifest, and says the name is free",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/applications/:name/versions", 404, %{
        "error" => "no_application",
        "message" => "EHOS has no application named invoice-pdf."
      })

      assert ehosctl(["verify"], opts) ==
               {0,
                @found <>
                  "EHOS at #{provider.issuer}:\n" <>
                  "  accepts ehos.yaml, as ehos.yaml/v8.\n" <>
                  "  accepts the manifest of invoice-pdf, as ehos.manifest/v9.\n" <>
                  "  has no application named invoice-pdf. When EHOS registers the first build, " <>
                  "invoice-pdf becomes a utility service.\n", ""}

      assert FakeProvider.requests(provider, "POST /api/v1/ehos-yaml/check") == [
               check_request(@ehos_yaml, "application/yaml"),
               check_request(@manifest, "application/json")
             ]

      assert [%{path: "/api/v1/applications/invoice-pdf/versions"}] =
               FakeProvider.requests(provider, "GET /api/v1/applications/invoice-pdf/versions")
    end

    test "says EHOS knows the name as a utility service", %{provider: provider, opts: opts} do
      versions(provider, "service")

      assert {0, stdout, ""} = ehosctl(["verify"], opts)
      assert stdout =~ "\n  knows the utility service invoice-pdf.\n"
    end

    test "refuses a name EHOS knows as an application's", %{provider: provider, opts: opts} do
      versions(provider, "application")

      assert ehosctl(["verify"], opts) ==
               {1, "",
                "ehosctl: invoice-pdf is the name of an application in EHOS. EHOS refuses a " <>
                  "utility service with the name of an application. Give the service another " <>
                  "name in the application key of ehos.yaml.\n"}
    end

    test "says it cannot tell when the person may not read the name's versions",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/applications/:name/versions", 403, %{
        "error" => "forbidden",
        "message" => "Reading invoice-pdf's versions needs ehos.application.register for it."
      })

      assert {0, stdout, ""} = ehosctl(["verify"], opts)

      assert stdout =~
               "\n  does not let you read the versions of invoice-pdf. So ehosctl cannot tell " <>
                 "if an application has this name. To read the versions, you need " <>
                 "ehos.application.register for invoice-pdf.\n"
    end

    test "when EHOS does not answer, says that it did not check the file, and that the bundle " <>
           "is written",
         %{provider: provider, service: service, opts: opts} do
      FakeProvider.down(provider)

      assert ehosctl(["verify"], opts) ==
               {5, "",
                "ehosctl: #{provider.issuer} did not answer. EHOS did not check ehos.yaml. " <>
                  "ehosctl checked it against its own copy of ehos.yaml/v8 and wrote the bundle " <>
                  "in _build/ehos.bundle.\n"}

      assert File.read!(Path.join(service, "_build/ehos.bundle/ehos.manifest.json")) == @manifest
    end
  end

  defp versions(provider, kind),
    do:
      api(provider, "GET", "/api/v1/applications/:name/versions", 200, %{
        "application" => "invoice-pdf",
        "kind" => kind,
        "versions" => [],
        "environments" => []
      })

  defp check_request(body, content_type),
    do: %{path: "/api/v1/ehos-yaml/check", query: %{}, body: body, content_type: content_type}

  defp accept_both(provider) do
    FakeProvider.stub_api(provider, "POST", "/api/v1/ehos-yaml/check", fn %{body: body} ->
      if String.starts_with?(body, "{"),
        do:
          {200,
           %{"valid" => true, "application" => "invoice-pdf", "version" => "ehos.manifest/v9"}},
        else: {200, %{"valid" => true, "version" => "ehos.yaml/v8", "latest" => "ehos.yaml/v8"}}
    end)
  end
end
