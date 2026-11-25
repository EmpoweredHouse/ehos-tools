defmodule Ehosctl.DeploymentHistoryTest do
  # `ehosctl apps history` (eh-os#802): an environment's deployments, as the console's tab shows
  # them, with what came after each.
  use Ehosctl.SignInCase

  @path "/api/v1/applications/ledger/environments/production/deployments"
  @image "ghcr.io/example/ledger@sha256:" <> String.duplicate("a1", 32)
  @other "ghcr.io/example/ledger@sha256:" <> String.duplicate("b2", 32)
  @in_force "1f0c2b3a-0000-4000-8000-000000000001"
  @superseded "2a9e8d7c-0000-4000-8000-000000000002"
  @failed "3b8f7e6d-0000-4000-8000-000000000003"
  @promotion "4c7a6b5e-0000-4000-8000-000000000004"

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    :ok
  end

  test "prints the deployment in force with its promotion, and what came after each before it",
       %{provider: provider, opts: opts} do
    in_force =
      deployment(@in_force, "active", @other, %{"promotion" => @promotion, "next" => nil})

    refused = %{
      "kind" => "refused",
      "id" => "e-1",
      "image" => @image,
      "digest" => "sha256:" <> String.duplicate("c3", 32),
      "by" => "ada@example.com",
      "why" => "ledger needs a database",
      "at" => "2026-10-21T07:00:00Z"
    }

    before = [
      deployment(@failed, "failed", @other, %{
        "failure" => "Back-off pulling image",
        "next" => next(@in_force, ["secrets"], ["api-key"])
      }),
      deployment(@superseded, "superseded", @image, %{
        "promotion" => @promotion,
        "next" => next(@in_force, ["image"])
      }),
      refused
    ]

    history(provider, in_force, before)

    {0, stdout, ""} = ehosctl(["apps", "history", "ledger", "--env", "production"], opts)

    assert stdout == """
           In force in production: deployment 1f0c2b3a-000 of ledger, active.
             image:     #{@other}
             manifest:  sha256:c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3
             promotion: #{@promotion}
             deployed:  21 October 2026, 08:00 UTC by ada@example.com
             address:   https://ledger.example.com

           Before it, newest first:
            WHEN                        DEPLOYMENT    IMAGE                OUTCOME                                                     AFTER IT
            21 October 2026, 08:00 UTC  3b8f7e6d-000  sha256:b2b2b2b2b2b2  failed: Back-off pulling image                              followed by the deployment in force: new versions of api-key
            21 October 2026, 08:00 UTC  2a9e8d7c-000  sha256:a1a1a1a1a1a1  superseded, promotion #{@promotion}  replaced by the deployment in force: a new image
            21 October 2026, 07:00 UTC  <none>        sha256:a1a1a1a1a1a1  refused: ledger needs a database                            <none>
           """

    assert FakeProvider.requests(provider, "GET #{@path}") == [
             %{path: @path, query: %{"limit" => "20"}, body: "", content_type: nil}
           ]

    {0, json, ""} = ehosctl(["apps", "history", "ledger", "--env", "production", "--json"], opts)

    # What came after each is kept with the fields it names, and nothing EHOS added beside them.
    assert JSON.decode!(json) == %{
             "application" => "ledger",
             "environment" => "production",
             "in_force" => in_force,
             "addresses" => ["https://ledger.example.com"],
             "before" => [
               deployment(@failed, "failed", @other, %{
                 "failure" => "Back-off pulling image",
                 "next" => kept(next(@in_force, ["secrets"], ["api-key"]))
               }),
               deployment(@superseded, "superseded", @image, %{
                 "promotion" => @promotion,
                 "next" => kept(next(@in_force, ["image"]))
               }),
               refused
             ]
           }
  end

  test "names no secret it was not given, and says nothing after one EHOS gives nothing for",
       %{provider: provider, opts: opts} do
    in_force = deployment(@in_force, "active", @other, %{})

    before = [
      deployment(@superseded, "superseded", @image, %{"next" => next(@in_force, ["secrets"])}),
      # An older EHOS gives neither next nor promotion; one of another shape is dropped.
      deployment(@failed, "failed", @image, %{"next" => %{"id" => 7}})
    ]

    history(provider, in_force, before)

    {0, stdout, ""} = ehosctl(["apps", "history", "ledger", "--env", "production"], opts)

    assert stdout == """
           In force in production: deployment 1f0c2b3a-000 of ledger, active.
             image:     #{@other}
             manifest:  sha256:c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3
             deployed:  21 October 2026, 08:00 UTC by ada@example.com
             address:   https://ledger.example.com

           Before it, newest first:
            WHEN                        DEPLOYMENT    IMAGE                OUTCOME     AFTER IT
            21 October 2026, 08:00 UTC  2a9e8d7c-000  sha256:a1a1a1a1a1a1  superseded  replaced by the deployment in force: new versions of secrets
            21 October 2026, 08:00 UTC  3b8f7e6d-000  sha256:a1a1a1a1a1a1  failed      <none>
           """

    {0, json, ""} = ehosctl(["apps", "history", "ledger", "--env", "production", "--json"], opts)

    assert JSON.decode!(json) == %{
             "application" => "ledger",
             "environment" => "production",
             "in_force" => in_force,
             "addresses" => ["https://ledger.example.com"],
             "before" => [
               deployment(@superseded, "superseded", @image, %{
                 "next" => kept(next(@in_force, ["secrets"]))
               }),
               deployment(@failed, "failed", @image, %{"next" => nil})
             ]
           }
  end

  test "says nothing is deployed, and lists the deployments there without one in force",
       %{provider: provider, opts: opts} do
    history(provider, nil, [])

    {0, stdout, ""} = ehosctl(["apps", "history", "ledger", "--env", "production"], opts)

    assert stdout == """
           No deployment of ledger is in force in production.

           No deployments of ledger are listed. A deployment shows here when a person or a pipeline deploys ledger there.
           """

    history(provider, nil, [deployment(@failed, "withdrawn", @image, %{})])
    {0, stdout, ""} = ehosctl(["apps", "history", "ledger", "--env", "production"], opts)

    assert stdout == """
           No deployment of ledger is in force in production.

           Its deployments, newest first:
            WHEN                        DEPLOYMENT    IMAGE                OUTCOME    AFTER IT
            21 October 2026, 08:00 UTC  3b8f7e6d-000  sha256:a1a1a1a1a1a1  withdrawn  <none>
           """
  end

  test "says what each change was, and which deployment followed when it is not in force",
       %{provider: provider, opts: opts} do
    in_force = deployment(@in_force, "active", @other, %{})
    failure = "Back-off pulling image: " <> String.duplicate("x", 80)

    before = [
      deployment(@failed, "failed", @other, %{
        "failure" => failure,
        "next" => next(@in_force, [])
      }),
      deployment(@superseded, "superseded", @image, %{
        "next" => next(@failed, ["image", "manifest"])
      }),
      %{"kind" => "refused", "id" => "e-1", "image" => nil, "why" => nil, "at" => nil}
    ]

    history(provider, in_force, before)

    {0, stdout, ""} = ehosctl(["apps", "history", "ledger", "--env", "production"], opts)

    # The failure is cut short as `apps show` cuts it; `--json` has it whole.
    assert stdout == """
           In force in production: deployment 1f0c2b3a-000 of ledger, active.
             image:     #{@other}
             manifest:  sha256:c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3
             deployed:  21 October 2026, 08:00 UTC by ada@example.com
             address:   https://ledger.example.com

           Before it, newest first:
            WHEN                        DEPLOYMENT    IMAGE                OUTCOME                                                               AFTER IT
            21 October 2026, 08:00 UTC  3b8f7e6d-000  sha256:b2b2b2b2b2b2  failed: Back-off pulling image: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx…  followed by the deployment in force: the same image, manifest and secrets
            21 October 2026, 08:00 UTC  2a9e8d7c-000  sha256:a1a1a1a1a1a1  superseded                                                            replaced by 3b8f7e6d-000: a new image, a new manifest
            <none>                      <none>        <none>               refused: <none>                                                       <none>
           """
  end

  test "says it cannot read them from an EHOS without the route, and exits 1",
       %{provider: provider, opts: opts} do
    FakeProvider.stub_api(provider, "GET", @path, fn _request ->
      {404, %{"errors" => %{"detail" => "Not Found"}}}
    end)

    FakeProvider.stub_api(provider, "GET", "/api/v1", fn _request ->
      {200,
       %{
         "component" => "ehos",
         "version" => "0.5.0",
         "commit" => nil,
         "produces" => ["ehos.api/v1"],
         "accepts" => ["ehos.manifest/v3"],
         "requires" => %{},
         "routes" => []
       }}
    end)

    {1, "", stderr} = ehosctl(["apps", "history", "ledger", "--env", "production"], opts)

    assert stderr ==
             "ehosctl: #{provider.issuer} runs EHOS 0.5.0, which has no `GET #{@path}`: this " <>
               "command needs a later EHOS. The operator upgrades EHOS to have it.\n"
  end

  test "needs --env", %{opts: opts} do
    {2, "", stderr} = ehosctl(["apps", "history", "ledger"], opts)

    assert stderr == """
           ehosctl: missing required options: --env

           See `ehosctl help apps history`.
           """
  end

  defp deployment(id, state, image, extra),
    do:
      Map.merge(
        %{
          "kind" => "deployment",
          "id" => id,
          "state" => state,
          "image" => image,
          "manifest_digest" => "sha256:" <> String.duplicate("c3", 32),
          "source" => nil,
          "failure" => nil,
          "by" => "ada@example.com",
          "at" => "2026-10-21T08:00:00Z"
        },
        extra
      )

  defp history(provider, in_force, before) do
    FakeProvider.stub_api(provider, "GET", @path, fn _request ->
      {200,
       %{
         "application" => "ledger",
         "environment" => "production",
         "in_force" => in_force,
         "addresses" => ["https://ledger.example.com"],
         "before" => before
       }}
    end)
  end

  defp next(id, changed, secrets \\ []),
    do: %{
      "id" => id,
      "state" => "active",
      "at" => "2026-10-21T09:00:00Z",
      "changed" => changed,
      "secrets" => secrets,
      "extra" => "not kept"
    }

  # What came after a deployment, as ehosctl keeps it: the fields it names.
  defp kept(next), do: Map.delete(next, "extra")
end
