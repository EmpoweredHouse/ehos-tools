defmodule Ehosctl.RoleBindingsTest do
  use Ehosctl.SignInCase

  @ada "0b9c2a8e-1f0e-4d43-9f5b-3a1c2d4e5f60"
  @agent "7d1e2f3a-4b5c-4d6e-8f90-a1b2c3d4e5f6"
  @binding "5a6b7c8d-9e0f-4a1b-8c2d-3e4f5a6b7c8d"

  @listed %{
    "id" => @binding,
    "role" => "ledger.clerk",
    "held_by" => %{"id" => @ada, "kind" => "person", "name" => "ada@example.com"},
    "application" => "ledger",
    "environment" => "staging",
    "gone" => false,
    "beyond_owner" => false
  }

  @principals [
    %{"id" => @ada, "kind" => "person", "email" => "ada@example.com"},
    %{"id" => @agent, "kind" => "agent", "name" => "month-closer", "owner" => "ada@example.com"}
  ]

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    :ok
  end

  defp api(provider, method, path, status, body),
    do: FakeProvider.stub_api(provider, method, path, fn _request -> {status, body} end)

  defp made(principal, role \\ "ledger.clerk", links \\ 0),
    do: %{
      "role_binding" => %{
        "id" => @binding,
        "role" => role,
        "principal" => principal,
        "sign_in_links_ended" => links
      }
    }

  # Answers each binding as EHOS would: of the role to the principal asked for, ending the
  # sign-in links of a person who has not joined, and none of an agent's, which has none.
  defp answer_bindings(provider, links) do
    FakeProvider.stub_api(provider, "POST", "/api/v1/role-bindings", fn %{body: body} ->
      %{"principal" => principal, "role" => role} = JSON.decode!(body)
      {201, made(principal, role, Map.get(links, principal, 0))}
    end)
  end

  test "lists the bindings, with where each holds and what is wrong with it",
       %{provider: provider, opts: opts} do
    gone = %{@listed | "id" => "b-2", "role" => "ledger.auditor", "gone" => true}

    platform = %{
      @listed
      | "id" => "b-3",
        "role" => "ehos.administrator",
        "application" => nil,
        "environment" => nil
    }

    api(provider, "GET", "/api/v1/role-bindings", 200, %{
      "role_bindings" => [@listed, gone, platform]
    })

    {0, stdout, ""} = ehosctl(["role-bindings", "list"], opts)
    assert stdout =~ ~r/ROLE\s+HELD BY\s+WHERE\s+NOTE\s+ID/
    assert stdout =~ ~r/ledger\.clerk\s+ada@example\.com\s+ledger in staging\s+#{@binding}/
    assert stdout =~ ~r/ledger\.auditor.*gone: grants nothing/
    assert stdout =~ ~r/ehos\.administrator\s+ada@example\.com\s+the whole platform/

    {0, json, ""} = ehosctl(["role-bindings", "list", "--json"], opts)
    assert %{"role_bindings" => [@listed | _]} = JSON.decode!(json)
  end

  test "binds a role to a person named by their email, in an application's environment",
       %{provider: provider, opts: opts} do
    api(provider, "GET", "/api/v1/role-bindings/principals", 200, %{"principals" => @principals})
    api(provider, "POST", "/api/v1/role-bindings", 201, made(@ada))

    args = ~w(role-bindings bind ledger.clerk --to Ada@Example.com --app ledger --env staging)
    {0, stdout, ""} = ehosctl(args, opts)

    assert stdout =~
             "Bound ledger.clerk to ada@example.com in ledger in staging: binding #{@binding}."

    assert [%{body: body}] = FakeProvider.requests(provider, "POST /api/v1/role-bindings")

    assert JSON.decode!(body) == %{
             "principal" => @ada,
             "role" => "ledger.clerk",
             "application" => "ledger",
             "environment" => "staging"
           }
  end

  test "binds an agent named by its owner's email and its name, and an id as it is",
       %{provider: provider, opts: opts} do
    api(provider, "GET", "/api/v1/role-bindings/principals", 200, %{"principals" => @principals})
    answer_bindings(provider, %{@ada => 1})

    args = ~w(role-bindings bind ehos.people_reader --to ada@example.com --agent month-closer)
    {0, stdout, ""} = ehosctl(args, opts)
    assert stdout =~ "to month-closer, the agent of ada@example.com at the whole platform"
    refute stdout =~ "sign-in link"

    # D-47: binding someone who has not joined ends the links they were sent.
    {0, stdout, ""} = ehosctl(~w(role-bindings bind ehos.people_reader --to #{@ada}), opts)
    assert stdout =~ "Their earlier sign-in link no longer works"

    assert [first, second] = FakeProvider.requests(provider, "POST /api/v1/role-bindings")
    assert JSON.decode!(first.body)["principal"] == @agent
    assert JSON.decode!(second.body) == %{"principal" => @ada, "role" => "ehos.people_reader"}
    # An id is sent as it is: only the email was looked up.
    assert [_] = FakeProvider.requests(provider, "GET /api/v1/role-bindings/principals")
  end

  test "says who cannot be found, and refuses what names nobody, before binding",
       %{provider: provider, opts: opts} do
    api(provider, "GET", "/api/v1/role-bindings/principals", 200, %{"principals" => @principals})

    {1, "", stderr} =
      ehosctl(~w(role-bindings bind ehos.people_reader --to bob@example.com), opts)

    assert stderr =~ "Nobody you may bind has the email bob@example.com"

    args = ~w(role-bindings bind ehos.people_reader --to ada@example.com --agent other)
    {1, "", stderr} = ehosctl(args, opts)
    assert stderr =~ "has no agent named other"

    {2, "", stderr} = ehosctl(~w(role-bindings bind ehos.people_reader --to ada), opts)
    assert stderr =~ "neither an email nor an id"

    {2, "", stderr} =
      ehosctl(~w(role-bindings bind ledger.clerk --to #{@ada} --env staging), opts)

    assert stderr =~ "--env needs --app"
    assert FakeProvider.requests(provider, "POST /api/v1/role-bindings") == []
  end

  test "prints EHOS's refusal in its words, with its kind's exit code",
       %{provider: provider, opts: opts} do
    for {status, code, exit} <- [
          {403, "escalation", 3},
          {422, "needs_environment", 2},
          {422, "production_only", 2},
          {409, "not_in_force", 1},
          {409, "last_administrator", 1}
        ] do
      api(provider, "POST", "/api/v1/role-bindings", status, %{
        "error" => code,
        "message" => "EHOS says #{code}."
      })

      {^exit, "", stderr} = ehosctl(~w(role-bindings bind ledger.clerk --to #{@ada}), opts)
      assert stderr =~ "EHOS says #{code}."
      # Known by its code, of the kind its exit says, not only by its status (eh-os's
      # docs/refusals.md).
      assert Ehosctl.Output.code(Ehosctl.Refusal.kind(code)) == exit
    end
  end

  # eh-os #703: several roles in one place, one request each, as the Bindings page binds them.
  test "binds several roles in one place, one request each, in the order given",
       %{provider: provider, opts: opts} do
    answer_bindings(provider, %{})

    args =
      ~w(role-bindings bind ledger.clerk ledger.auditor ledger.clerk --to #{@ada} --app ledger --env staging)

    {0, stdout, ""} = ehosctl(args, opts)
    assert stdout =~ "Bound ledger.clerk to #{@ada} in ledger in staging"
    assert stdout =~ "Bound ledger.auditor to #{@ada} in ledger in staging"

    # Each role once, in the order given.
    assert ["ledger.clerk", "ledger.auditor"] ==
             provider
             |> FakeProvider.requests("POST /api/v1/role-bindings")
             |> Enum.map(&JSON.decode!(&1.body)["role"])

    {0, stdout, ""} = ehosctl(args ++ ["--json"], opts)

    assert %{
             "role_bindings" => [%{"role" => "ledger.clerk"}, %{"role" => "ledger.auditor"}],
             "refused" => []
           } =
             JSON.decode!(stdout)
  end

  test "a role refused among several is said by role, the rest bound, and exits with its kind",
       %{provider: provider, opts: opts} do
    FakeProvider.stub_api(provider, "POST", "/api/v1/role-bindings", fn %{body: body} ->
      case JSON.decode!(body) do
        %{"role" => "ehos.administrator"} ->
          {403, %{"error" => "escalation", "message" => "You do not hold what it grants."}}

        %{"principal" => principal, "role" => role} ->
          {201, made(principal, role)}
      end
    end)

    args = ~w(role-bindings bind ehos.administrator ehos.people_reader --to #{@ada})
    {3, stdout, stderr} = ehosctl(args, opts)

    # What was bound on stdout, what was refused on stderr.
    assert stdout =~ "Bound ehos.people_reader to #{@ada}"
    assert stderr =~ "ehos.administrator: You do not hold what it grants."
    refute stderr =~ "Bound"
    assert [_, _] = FakeProvider.requests(provider, "POST /api/v1/role-bindings")

    # As JSON, both, with the refusal's kind, and the same exit code.
    {3, stdout, ""} = ehosctl(args ++ ["--json"], opts)

    assert %{
             "role_bindings" => [%{"role" => "ehos.people_reader"}],
             "refused" => [
               %{"role" => "ehos.administrator", "kind" => "refused", "refusal" => refusal}
             ],
             "not_asked" => []
           } = JSON.decode!(stdout)

    assert refusal =~ "You do not hold what it grants."
  end

  test "roles are not asked once being signed out would refuse every one",
       %{provider: provider, opts: opts} do
    api(provider, "POST", "/api/v1/role-bindings", 401, %{
      "error" => "expired",
      "message" => "Your sign-in has expired."
    })

    {4, "", stderr} =
      ehosctl(~w(role-bindings bind ehos.people_reader ehos.log_reader --to #{@ada}), opts)

    assert stderr =~ "ehos.log_reader: not asked."
    assert [_] = FakeProvider.requests(provider, "POST /api/v1/role-bindings")
  end

  test "one role named twice answers as several, each role once", %{
    provider: provider,
    opts: opts
  } do
    answer_bindings(provider, %{})

    {0, stdout, ""} =
      ehosctl(
        ~w(role-bindings bind ehos.people_reader ehos.people_reader --to #{@ada} --json),
        opts
      )

    assert %{"role_bindings" => [%{"role" => "ehos.people_reader"}], "refused" => []} =
             JSON.decode!(stdout)

    assert [_] = FakeProvider.requests(provider, "POST /api/v1/role-bindings")
  end

  test "an option bind does not take is not taken for a role", %{provider: provider, opts: opts} do
    {2, "", stderr} =
      ehosctl(~w(role-bindings bind ledger.clerk --to #{@ada} --evn staging), opts)

    assert stderr =~ "--evn is not an option of bind"
    assert FakeProvider.requests(provider, "POST /api/v1/role-bindings") == []
  end

  test "lists one principal's bindings, named as bind names them", %{
    provider: provider,
    opts: opts
  } do
    agents = %{
      @listed
      | "id" => "b-2",
        "held_by" => %{"id" => @agent, "kind" => "agent", "name" => "month-closer"}
    }

    api(provider, "GET", "/api/v1/role-bindings", 200, %{"role_bindings" => [@listed, agents]})
    api(provider, "GET", "/api/v1/role-bindings/principals", 200, %{"principals" => @principals})

    {0, stdout, ""} = ehosctl(~w(role-bindings list --to ada@example.com --json), opts)
    assert %{"role_bindings" => [%{"id" => @binding}]} = JSON.decode!(stdout)

    {0, stdout, ""} =
      ehosctl(~w(role-bindings list --to ada@example.com --agent month-closer --json), opts)

    assert %{"role_bindings" => [%{"id" => "b-2"}]} = JSON.decode!(stdout)

    # An id in either case, as EHOS reads it.
    {0, stdout, ""} = ehosctl(~w(role-bindings list --to #{String.upcase(@ada)} --json), opts)
    assert %{"role_bindings" => [%{"id" => @binding}]} = JSON.decode!(stdout)

    {2, "", stderr} = ehosctl(~w(role-bindings list --agent month-closer), opts)
    assert stderr =~ "--agent needs --to"

    # Someone who holds nothing here is said to, not that there is nothing at all.
    other = "11111111-2222-4333-8444-555555555555"
    {0, stdout, ""} = ehosctl(~w(role-bindings list --to #{other}), opts)
    assert stdout =~ "They hold no role in the scopes where you manage bindings."
  end

  test "a listing refused to someone who manages no binding exits 3",
       %{provider: provider, opts: opts} do
    api(provider, "GET", "/api/v1/role-bindings", 403, %{
      "error" => "forbidden",
      "message" => "Reading the role bindings needs ehos.role_binding.manage, held anywhere."
    })

    {3, "", stderr} = ehosctl(["role-bindings", "list"], opts)
    assert stderr =~ "ehos.role_binding.manage"
  end

  test "a binding EHOS answers of another role or principal is not taken for the one asked",
       %{provider: provider, opts: opts} do
    for answer <- [made(@agent), made(@ada, "ledger.auditor")] do
      api(provider, "POST", "/api/v1/role-bindings", 201, answer)

      {1, "", stderr} = ehosctl(~w(role-bindings bind ledger.clerk --to #{@ada}), opts)
      assert stderr =~ "not as what was asked"
      assert stderr =~ "run `ehosctl role-bindings list` to see what was done"
    end
  end

  test "unbinds a binding by its id, in either case", %{provider: provider, opts: opts} do
    api(provider, "DELETE", "/api/v1/role-bindings/#{String.upcase(@binding)}", 200, %{
      "role_binding" => %{"id" => @binding, "role" => "ledger.clerk"}
    })

    {0, stdout, ""} = ehosctl(["role-bindings", "unbind", String.upcase(@binding)], opts)
    assert stdout =~ "Removed the binding of ledger.clerk, #{@binding}."
  end

  test "an unbinding EHOS says it did of another binding is not taken for this one",
       %{provider: provider, opts: opts} do
    api(provider, "DELETE", "/api/v1/role-bindings/#{@binding}", 200, %{
      "role_binding" => %{"id" => "another", "role" => "ledger.clerk"}
    })

    {1, "", stderr} = ehosctl(["role-bindings", "unbind", @binding], opts)
    assert stderr =~ "run `ehosctl role-bindings list` to see"
  end

  test "a binding that leaves out where it holds reads as null there",
       %{provider: provider, opts: opts} do
    platform = Map.drop(@listed, ["application", "environment"])
    application = Map.delete(@listed, "environment")

    api(provider, "GET", "/api/v1/role-bindings", 200, %{
      "role_bindings" => [platform, application]
    })

    {0, stdout, ""} = ehosctl(["role-bindings", "list"], opts)
    assert stdout =~ ~r/ledger\.clerk\s+ada@example\.com\s+the whole platform/
    assert stdout =~ ~r/ledger\.clerk\s+ada@example\.com\s+ledger\s+#{@binding}/
  end

  test "an answer that is not a listing is not printed as one", %{provider: provider, opts: opts} do
    api(provider, "GET", "/api/v1/role-bindings", 200, %{
      "role_bindings" => [%{@listed | "held_by" => "ada"}]
    })

    {1, "", stderr} = ehosctl(["role-bindings", "list"], opts)
    assert stderr =~ "cannot read"
  end
end
