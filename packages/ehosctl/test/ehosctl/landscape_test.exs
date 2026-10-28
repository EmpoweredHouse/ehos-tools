defmodule Ehosctl.LandscapeTest do
  # `ehosctl landscape --env E` (eh-os D-123, ehos-tools#361): an environment's landscape, from
  # `GET /api/v1/environments/E/landscape` (eh-os#791).
  use Ehosctl.SignInCase

  @path "/api/v1/environments/staging/landscape"

  # Three applications as eh_os_contract_graph's join gives them: tax publishes the opening of
  # an accounting month, which ledger subscribes to; ledger also subscribes to payroll's, which no
  # application here publishes. lending publishes and subscribes to nothing, and an EHOS from
  # before eh-os#900 names its domain as quiet.
  @landscape %{
    "kind" => "landscape",
    "nodes" => %{
      "domain" => [
        %{"id" => "0/domain:Ledger.Domain", "application" => "ledger", "name" => "ledger"},
        %{
          "id" => "1/domain:Tax.Domain",
          "application" => "tax",
          "name" => "tax"
        },
        %{"id" => "2/domain:Lending.Domain", "application" => "lending", "name" => "lending"}
      ],
      "contract" => [
        %{"id" => "0/contract:ledger.month", "in" => "0/domain:Ledger.Domain"},
        %{"id" => "1/contract:tax.month", "in" => "1/domain:Tax.Domain"}
      ],
      "publication" => [
        %{
          "id" => "publication:tax.accounting_month.opened.v1",
          "name" => "tax.accounting_month.opened.v1",
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
          "from" => "1/contract:tax.month",
          "to" => "publication:tax.accounting_month.opened.v1"
        }
      ],
      "subscribed_by" => [
        %{
          "from" => "publication:tax.accounting_month.opened.v1",
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
    "quiet_domains" => [%{"application" => "lending", "domain" => "lending"}]
  }

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    :ok
  end

  defp serve(provider, answer),
    do: FakeProvider.stub_api(provider, "GET", @path, fn _ -> answer end)

  # D-134 (eh-os#890): the deployment each drawn application's box comes from.
  @deployments %{"ledger" => "deployment-of-ledger", "tax" => "deployment-of-tax"}

  defp answer(landscape \\ @landscape, beside \\ @beside),
    do:
      {200,
       %{
         "environment" => "staging",
         "landscape" => landscape,
         "deployments" => @deployments,
         "beside" => beside
       }}

  test "prints who publishes each fact and who subscribes to it, and what is left out",
       %{provider: provider, opts: opts} do
    serve(provider, answer())

    {0, stdout, ""} = ehosctl(["landscape", "--env", "staging"], opts)

    assert stdout == """
           The landscape of staging

           Drawn: ledger, tax

           On the wire:
             payroll.run.closed.v1
               published by no application you may see here
               subscribed to by ledger
             tax.accounting_month.opened.v1
               published by tax
               subscribed to by ledger

           Drawn from these deployments; `ehosctl graph APPLICATION DEPLOYMENT` lists what one carried:
             ledger: deployment-of-ledger
             tax: deployment-of-tax

           No active deployment here, so not drawn: failing

           Their active deployment sent no graph documents, so not drawn: nodocs

           Sent graph documents of a version this EHOS does not read; what they say is drawn once its pipeline deploys again to an EHOS that reads it:
             ledger: version 2

           Publishing and subscribing to nothing, so without a box: lending · lending
           """
  end

  test "draws an application that publishes and subscribes to nothing, as an EHOS that names no quiet domain answers",
       %{provider: provider, opts: opts} do
    alone = %{
      "kind" => "landscape",
      "nodes" => %{
        "domain" => [
          %{"id" => "0/domain:Lending.Domain", "application" => "lending", "name" => "lending"}
        ],
        "contract" => [],
        "publication" => []
      },
      "relations" => %{"publishes" => [], "subscribed_by" => []}
    }

    # As eh-os#900 answers it, and as an EHOS that leaves the list out would.
    for beside <- [
          %{@beside | "unread_versions" => [], "quiet_domains" => []},
          Map.drop(%{@beside | "unread_versions" => []}, ["quiet_domains"])
        ] do
      serve(provider, answer(alone, beside))

      {0, stdout, ""} = ehosctl(["landscape", "--env", "staging"], opts)
      assert stdout =~ "Drawn: lending\n\nOn the wire: nothing.\n\n"
      refute stdout =~ "Nothing is drawn"
      refute stdout =~ "without a box"
    end
  end

  test "says nothing is drawn, and why, where an EHOS from before eh-os#900 draws no quiet domain",
       %{provider: provider, opts: opts} do
    alone = %{
      "kind" => "landscape",
      "nodes" => %{
        "domain" => [
          %{"id" => "0/domain:Lending.Domain", "application" => "lending", "name" => "lending"}
        ],
        "contract" => [],
        "publication" => []
      },
      "relations" => %{"publishes" => [], "subscribed_by" => []}
    }

    serve(provider, answer(alone, %{@beside | "unread_versions" => []}))

    {0, stdout, ""} = ehosctl(["landscape", "--env", "staging"], opts)

    assert stdout =~
             "Nothing is drawn in staging: no application you may see has an active deployment " <>
               "there that declares a fact it publishes or subscribes to."

    assert stdout =~ "Publishing and subscribing to nothing, so without a box: lending · lending"
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

    assert stdout =~
             "Nothing is drawn in staging: no application you may see has an active deployment " <>
               "there that sent a domain's graph document this EHOS reads."

    assert stdout =~ "No active deployment here, so not drawn: failing"
  end

  # eh-os D-137: how many applications running there the reader may not see, none named.
  test "says how many applications here it leaves out for the reader, and only when there are any",
       %{provider: provider, opts: opts} do
    for {count, said} <- [
          {1, "One application running here is not one you may see"},
          {3, "3 applications running here are not ones you may see"}
        ] do
      serve(provider, answer(@landscape, Map.put(@beside, "hidden_applications", count)))
      {0, stdout, ""} = ehosctl(["landscape", "--env", "staging"], opts)
      assert stdout =~ said
      assert stdout =~ "`ehosctl roles` lists the ones you hold."
    end

    serve(provider, answer(@landscape, Map.put(@beside, "hidden_applications", 0)))
    {0, stdout, ""} = ehosctl(["landscape", "--env", "staging"], opts)
    refute stdout =~ "running here"
  end

  test "--json prints EHOS's answer", %{provider: provider, opts: opts} do
    {200, body} = answer()
    serve(provider, {200, Map.put(body, "later", "a key EHOS adds later")})

    {0, stdout, ""} = ehosctl(["landscape", "--env", "staging", "--json"], opts)
    assert JSON.decode!(stdout) == body
  end

  test "reads an answer from an EHOS that names no deployments, and says none",
       %{provider: provider, opts: opts} do
    {200, body} = answer()

    for answer <- [Map.delete(body, "deployments"), %{body | "deployments" => %{}}] do
      serve(provider, {200, answer})
      {0, stdout, ""} = ehosctl(["landscape", "--env", "staging"], opts)
      refute stdout =~ "Drawn from these deployments"
    end

    serve(provider, {200, Map.delete(body, "deployments")})

    {0, stdout, ""} = ehosctl(["landscape", "--env", "staging", "--json"], opts)
    refute Map.has_key?(JSON.decode!(stdout), "deployments")
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

  # eh-os#1078: an application whose active deployment sent no graph documents EHOS reads is a box
  # nothing describes, among the landscape's `application` nodes; `beside` still names it.
  @undescribed %{
    "kind" => "landscape",
    "nodes" => %{
      "domain" => [
        %{"id" => "0/domain:Ledger.Domain", "application" => "ledger", "name" => "ledger"}
      ],
      "application" => [
        %{"id" => "1/application:nodocs", "application" => "nodocs", "label" => "nodocs"},
        %{"id" => "2/application:unread", "application" => "unread", "label" => "unread"}
      ],
      "contract" => [],
      "publication" => []
    },
    "relations" => %{"publishes" => [], "subscribed_by" => []}
  }

  test "draws an application nothing describes as its box, as an EHOS since eh-os#1078 answers",
       %{provider: provider, opts: opts} do
    beside = %{
      "no_active_deployment" => [],
      "no_documents" => ["nodocs"],
      "unread_versions" => [%{"application" => "unread", "versions" => [2]}],
      "quiet_domains" => []
    }

    serve(provider, answer(@undescribed, beside))

    {0, stdout, ""} = ehosctl(["landscape", "--env", "staging"], opts)

    assert stdout =~ "Drawn: ledger, nodocs (no graph described), unread (no graph described)\n"
    refute stdout =~ "so not drawn: nodocs"
    assert stdout =~ "  unread: version 2"
  end

  test "draws applications nothing describes when they are all there is",
       %{provider: provider, opts: opts} do
    alone = put_in(@undescribed, ["nodes", "domain"], [])

    beside = %{
      "no_active_deployment" => [],
      "no_documents" => ["nodocs"],
      "unread_versions" => []
    }

    serve(provider, answer(alone, beside))

    {0, stdout, ""} = ehosctl(["landscape", "--env", "staging"], opts)

    assert stdout =~ "Drawn: nodocs (no graph described), unread (no graph described)\n"
    refute stdout =~ "Nothing is drawn"
  end

  test "refuses an answer it cannot read, rather than print it in part",
       %{provider: provider, opts: opts} do
    nameless = put_in(@landscape, ["nodes", "domain"], [%{"id" => "d", "application" => %{}}])

    unnamed =
      put_in(@undescribed, ["nodes", "application"], [%{"id" => "a", "application" => nil}])

    {200, undescribed} = answer(unnamed)
    {200, not_a_list} = answer(put_in(@undescribed, ["nodes", "application"], %{}))

    {200, body} = answer()

    for answer <- [
          answer(%{"nodes" => []}),
          answer(nameless),
          {200, undescribed},
          {200, not_a_list},
          {200, %{body | "deployments" => %{"ledger" => 1}}},
          answer(@landscape, Map.put(@beside, "hidden_applications", -1)),
          answer(@landscape, Map.put(@beside, "hidden_applications", "2")),
          answer(@landscape, Map.put(@beside, "hidden_applications", 2.0)),
          answer(@landscape, Map.put(@beside, "hidden_applications", true))
        ] do
      serve(provider, answer)
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

  test "refuses an environment that names nothing, or . or .., before asking EHOS",
       %{opts: opts} do
    for env <- ["", ".", ".."] do
      {2, "", stderr} = ehosctl(["landscape", "--env", env], opts)
      assert stderr =~ "#{inspect(env)} names no environment."
    end
  end

  test "--env is required", %{opts: opts} do
    {code, _stdout, stderr} = ehosctl(["landscape"], opts)
    assert code != 0
    assert stderr =~ "--env"
  end
end
