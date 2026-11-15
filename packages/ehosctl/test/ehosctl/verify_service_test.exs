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

  @found "ehos.yaml describes the utility service invoice-pdf. ehosctl checked it against the " <>
           "schema ehos.yaml/v8 and found no error. EHOS checks more rules than the schema.\n" <>
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

      assert Bundle.read(bundle) ==
               {:ok,
                %{
                  index: Bundle.index(@manifest),
                  manifest: @manifest,
                  graphs: [],
                  graph_bytes: 0,
                  openapi: nil,
                  application: "invoice-pdf"
                }}
    end

    test "puts the repository's OpenAPI file into the bundle as it is, and the bundle is v2",
         %{service: service, opts: opts} do
      File.write!(Path.join(service, "openapi.yaml"), "openapi: 3.1.0\n")

      assert ehosctl(["verify"], opts) ==
               {0,
                String.replace(
                  @found,
                  "schema.\n",
                  "schema.\nThe bundle holds the OpenAPI file openapi.yaml, as it is. EHOS " <>
                    "does not check it.\n"
                ) <> @no_installation, ""}

      bundle = Path.join(service, "_build/ehos.bundle")

      assert {:ok, %{openapi: %{path: "openapi.yaml", bytes: "openapi: 3.1.0\n"}}} =
               Ehosctl.Bundle.read(bundle)

      assert JSON.decode!(File.read!(Path.join(bundle, "bundle.json")))["schema"] ==
               "ehos.bundle/v2"
    end

    test "refuses two OpenAPI files, an empty one, and one larger than EHOS takes, and writes " <>
           "no bundle",
         %{service: service, opts: opts} do
      File.write!(Path.join(service, "openapi.json"), "{}")
      File.write!(Path.join(service, "openapi.yaml"), "openapi: 3.1.0\n")

      assert ehosctl(["verify"], opts) ==
               {2, "",
                "ehosctl: This directory holds openapi.json and openapi.yaml. A utility service " <>
                  "has one OpenAPI file: keep one of them. ehosctl wrote no bundle.\n"}

      File.rm!(Path.join(service, "openapi.json"))
      File.write!(Path.join(service, "openapi.yaml"), "")

      assert ehosctl(["verify"], opts) ==
               {2, "",
                "ehosctl: openapi.yaml is empty. A bundle holds an OpenAPI file of 1 to 1048576 " <>
                  "bytes. ehosctl wrote no bundle.\n"}

      File.write!(Path.join(service, "openapi.yaml"), String.duplicate("#", 1_048_577))

      assert ehosctl(["verify"], opts) ==
               {1, "",
                "ehosctl: openapi.yaml is larger than the 1048576 bytes EHOS takes. ehosctl " <>
                  "wrote no bundle.\n"}

      refute File.exists?(Path.join(service, "_build/ehos.bundle"))
    end

    test "replaces the bundle an earlier run left", %{service: service, opts: opts} do
      stale = Path.join(service, "_build/ehos.bundle/graph/removed.json")
      File.mkdir_p!(Path.dirname(stale))
      File.write!(stale, "{}")

      {0, _stdout, ""} = ehosctl(["verify"], opts)

      refute File.exists?(stale)
    end

    test "removes the bundle an earlier run left when it refuses the file, so none is registered",
         %{service: service, opts: opts} do
      {0, _stdout, ""} = ehosctl(["verify"], opts)
      File.write!(Path.join(service, "ehos.yaml"), @ehos_yaml <> "needs: {people: read}\n")

      assert {2, "", _refused} = ehosctl(["verify"], opts)

      refute File.exists?(Path.join(service, "_build/ehos.bundle"))
    end

    test "refuses a link at _build, which the bundle would be written through",
         %{service: service, opts: opts, tmp_dir: tmp} do
      elsewhere = Path.join(tmp, "elsewhere")
      File.mkdir_p!(Path.join(elsewhere, "ehos.bundle"))
      File.write!(Path.join(elsewhere, "ehos.bundle/kept"), "kept")
      File.ln_s!(elsewhere, Path.join(service, "_build"))

      assert ehosctl(["verify"], opts) ==
               {2, "", "ehosctl: _build is not a directory (symlink).\n"}

      assert File.read!(Path.join(elsewhere, "ehos.bundle/kept")) == "kept"
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
      # As eh-os's `EhosWeb.VersionController` answers a name it does not know.
      api(provider, "GET", "/api/v1/applications/:name/versions", 404, %{
        "error" => "not_found",
        "message" => "No application is named invoice-pdf."
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

      assert ehosctl(["verify"], opts) ==
               {0, @found <> accepted(provider) <> "  knows the utility service invoice-pdf.\n",
                ""}
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

      assert ehosctl(["verify"], opts) ==
               {0,
                @found <>
                  accepted(provider) <>
                  "  does not let you read the versions of invoice-pdf. So ehosctl cannot tell " <>
                  "if an application has this name. To read the versions, you need " <>
                  "ehos.application.register for invoice-pdf.\n", ""}
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

    test "when EHOS stops answering after it accepts ehos.yaml, says that it did not check " <>
           "the manifest",
         %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "POST", "/api/v1/ehos-yaml/check", fn _request ->
        FakeProvider.down(provider)
        {200, %{"valid" => true, "version" => "ehos.yaml/v8", "latest" => "ehos.yaml/v8"}}
      end)

      assert ehosctl(["verify"], opts) ==
               {5, "",
                "ehosctl: #{provider.issuer} did not answer. EHOS accepted ehos.yaml and did " <>
                  "not check the manifest. ehosctl wrote the bundle in _build/ehos.bundle.\n"}
    end

    test "when EHOS stops answering after it accepts both files, says that it accepted them",
         %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "POST", "/api/v1/ehos-yaml/check", fn %{body: body} ->
        if String.starts_with?(body, "{") do
          FakeProvider.down(provider)

          {200,
           %{"valid" => true, "application" => "invoice-pdf", "version" => "ehos.manifest/v9"}}
        else
          {200, %{"valid" => true, "version" => "ehos.yaml/v8", "latest" => "ehos.yaml/v8"}}
        end
      end)

      assert ehosctl(["verify"], opts) ==
               {5, "",
                "ehosctl: #{provider.issuer} did not answer. EHOS accepted ehos.yaml and the " <>
                  "manifest, and did not say if it knows the name. ehosctl wrote the bundle in " <>
                  "_build/ehos.bundle.\n"}
    end
  end

  defp accepted(provider),
    do:
      "EHOS at #{provider.issuer}:\n" <>
        "  accepts ehos.yaml, as ehos.yaml/v8.\n" <>
        "  accepts the manifest of invoice-pdf, as ehos.manifest/v9.\n"

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
