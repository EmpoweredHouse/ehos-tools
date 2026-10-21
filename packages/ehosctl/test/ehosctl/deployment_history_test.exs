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

  test "prints the deployment in force with its promotion, and what came after each before it",
       %{provider: provider, opts: opts} do
    in_force =
      deployment(@in_force, "active", @other, %{"promotion" => @promotion, "next" => nil})

    before = [
      deployment(@failed, "failed", @other, %{
        "failure" => "Back-off pulling image",
        "next" => next(@in_force, ["secrets"], ["api-key"])
      }),
      deployment(@superseded, "superseded", @image, %{
        "promotion" => @promotion,
        "next" => next(@in_force, ["image"])
      }),
      %{
        "kind" => "refused",
        "id" => "e-1",
        "image" => @image,
        "digest" => "sha256:" <> String.duplicate("c3", 32),
        "by" => "ada@example.com",
        "why" => "ledger needs a database",
        "at" => "2026-10-21T07:00:00Z"
      }
    ]

    history(provider, in_force, before)

    {0, stdout, ""} = ehosctl(["apps", "history", "ledger", "--env", "production"], opts)

    assert stdout =~ "In force in production: ledger's deployment 1f0c2b3a-000, active."
    assert stdout =~ "  promotion: #{@promotion}\n"
    assert stdout =~ "  address:   https://ledger.example.com\n"
    assert stdout =~ ~r/3b8f7e6d-000\s+sha256:b2b2b2b2b2b2\s+failed: Back-off pulling image\s+/
    assert stdout =~ "followed by the deployment in force: new versions of api-key"
    assert stdout =~ "superseded, promoted by 4c7a6b5e-000"
    assert stdout =~ "replaced by the deployment in force: a new image"
    assert stdout =~ "refused: ledger needs a database"

    assert [request] = FakeProvider.requests(provider, "GET #{@path}")
    assert request.query == %{"limit" => "20"}

    {0, json, ""} = ehosctl(["apps", "history", "ledger", "--env", "production", "--json"], opts)
    decoded = JSON.decode!(json)
    assert decoded["in_force"]["promotion"] == @promotion
    assert [%{"next" => kept} | _] = decoded["before"]
    assert kept == Map.delete(next(@in_force, ["secrets"], ["api-key"]), "extra")
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
    assert stdout =~ "replaced by the deployment in force: new versions of secrets"
    refute stdout =~ "promotion:"

    {0, json, ""} = ehosctl(["apps", "history", "ledger", "--env", "production", "--json"], opts)
    decoded = JSON.decode!(json)
    refute Map.has_key?(decoded["in_force"], "promotion")
    assert [_superseded, %{"next" => nil}] = decoded["before"]
  end

  test "says nothing is deployed, and nothing before it", %{provider: provider, opts: opts} do
    history(provider, nil, [])

    {0, stdout, ""} = ehosctl(["apps", "history", "ledger", "--env", "production"], opts)
    assert stdout =~ "Nothing of ledger is deployed in production."
    assert stdout =~ "Nothing before it."
  end

  test "needs --env", %{opts: opts} do
    assert {2, "", stderr} = ehosctl(["apps", "history", "ledger"], opts)
    assert stderr =~ "--env"
  end
end
