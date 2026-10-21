defmodule Ehosctl.LandscapeTest do
  # `ehosctl landscape --env E` (eh-os D-123, ehos-tools#361): an environment's landscape, from
  # `GET /api/v1/environments/E/landscape` (eh-os#791).
  use Ehosctl.SignInCase

  @path "/api/v1/environments/staging/landscape"

  # Two applications as eh_os_contract_graph's join gives them: taxvision publishes the opening of
  # an accounting month, which ledger subscribes to; ledger also subscribes to payroll's, which no
  # application here publishes.
  @landscape %{
    "kind" => "landscape",
    "nodes" => %{
      "domain" => [
        %{"id" => "0/domain:Ledger.Domain", "application" => "ledger", "name" => "ledger"},
        %{
          "id" => "1/domain:Taxvision.Domain",
          "application" => "taxvision",
          "name" => "taxvision"
        },
        %{"id" => "2/domain:Rehmed.Domain", "application" => "rehmed", "name" => "rehmed"}
      ],
      "contract" => [
        %{"id" => "0/contract:ledger.month", "in" => "0/domain:Ledger.Domain"},
        %{"id" => "1/contract:taxvision.month", "in" => "1/domain:Taxvision.Domain"}
      ],
      "publication" => [
        %{
          "id" => "publication:taxvision.accounting_month.opened.v1",
          "name" => "taxvision.accounting_month.opened.v1",
          "outside" => false
        },
        %{
          "id" => "publication:payroll.run.closed.v1",
          "name" => "payroll.run.closed.v1",
          "outside" => true
        }
      ],
      "event" => []
    },
    "relations" => %{
      "publishes" => [
        %{
          "from" => "1/contract:taxvision.month",
          "to" => "publication:taxvision.accounting_month.opened.v1"
        }
      ],
      "subscribed_by" => [
        %{
          "from" => "publication:taxvision.accounting_month.opened.v1",
          "to" => "0/contract:ledger.month"
        },
        %{"from" => "publication:payroll.run.closed.v1", "to" => "0/contract:ledger.month"}
      ]
    }
  }

  @beside %{
    "no_active_deployment" => ["failing"],
    "no_documents" => ["nodocs"],
    "unread_versions" => [%{"application" => "ledger", "versions" => [2]}],
    "quiet_domains" => [%{"application" => "rehmed", "domain" => "rehmed"}]
  }

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    :ok
  end

  defp serve(provider, answer),
    do: FakeProvider.stub_api(provider, "GET", @path, fn _ -> answer end)

  defp answer(landscape \\ @landscape, beside \\ @beside),
    do: {200, %{"environment" => "staging", "landscape" => landscape, "beside" => beside}}

  test "prints who publishes each fact and who subscribes to it, and what is left out",
       %{provider: provider, opts: opts} do
    serve(provider, answer())

    {0, stdout, ""} = ehosctl(["landscape", "--env", "staging"], opts)

    assert stdout == """
           The landscape of staging

           Drawn: ledger, taxvision

           On the wire:
             payroll.run.closed.v1
               published by no application you may see here
               subscribed to by ledger
             taxvision.accounting_month.opened.v1
               published by taxvision
               subscribed to by ledger

           No active deployment here, so not drawn: failing

           Their active deployment sent no graph documents, so not drawn: nodocs

           Sent graph documents of a version this EHOS does not read; what they say is drawn once its pipeline deploys again to an EHOS that reads it:
             ledger: version 2

           Publishing and subscribing to nothing, so without a box: rehmed · rehmed
           """
  end

  test "says so when nothing is drawn", %{provider: provider, opts: opts} do
    empty = %{
      "kind" => "landscape",
      "nodes" => %{"domain" => [], "contract" => [], "publication" => []},
      "relations" => %{"publishes" => [], "subscribed_by" => []}
    }

    serve(
      provider,
      answer(empty, %{@beside | "unread_versions" => [], "quiet_domains" => []})
    )

    {0, stdout, ""} = ehosctl(["landscape", "--env", "staging"], opts)
    assert stdout =~ "Nothing is drawn in staging"
    assert stdout =~ "No active deployment here, so not drawn: failing"
  end

  test "--json prints EHOS's answer", %{provider: provider, opts: opts} do
    {200, body} = answer()
    serve(provider, {200, Map.put(body, "later", "a key EHOS adds later")})

    {0, stdout, ""} = ehosctl(["landscape", "--env", "staging", "--json"], opts)
    assert JSON.decode!(stdout) == body
  end

  test "a refused read exits with EHOS's sentence", %{provider: provider, opts: opts} do
    serve(
      provider,
      {403,
       %{
         "error" => "forbidden",
         "message" =>
           "Reading staging's landscape needs ehos.application.deploy or " <>
             "ehos.application.register for an application there."
       }}
    )

    {3, "", stderr} = ehosctl(["landscape", "--env", "staging"], opts)
    assert stderr =~ "Reading staging's landscape needs"
  end

  test "refuses an answer it cannot read, rather than print it in part",
       %{provider: provider, opts: opts} do
    nameless = put_in(@landscape, ["nodes", "domain"], [%{"id" => "d", "application" => %{}}])

    for landscape <- [%{"nodes" => []}, nameless] do
      serve(provider, answer(landscape))
      {code, "", stderr} = ehosctl(["landscape", "--env", "staging"], opts)
      assert code != 0
      assert stderr != ""
    end
  end

  test "shows text another application wrote as text, not as it is",
       %{provider: provider, opts: opts} do
    landscape =
      put_in(
        @landscape,
        ["nodes", "publication"],
        [%{"id" => "p", "name" => "evil\e[2J.v1", "outside" => true}]
      )

    serve(provider, answer(landscape))

    {0, stdout, ""} = ehosctl(["landscape", "--env", "staging"], opts)
    refute stdout =~ "\e[2J"
  end

  test "--env is required", %{opts: opts} do
    {code, _stdout, stderr} = ehosctl(["landscape"], opts)
    assert code != 0
    assert stderr =~ "--env"
  end
end
