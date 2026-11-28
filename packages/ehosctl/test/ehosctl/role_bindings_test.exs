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

  describe "role-bindings list" do
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

      assert stdout == """
              ROLE                HELD BY          WHERE               NOTE                  ID
              ledger.clerk        ada@example.com  ledger in staging                         #{@binding}
              ledger.auditor      ada@example.com  ledger in staging   gone: grants nothing  b-2
              ehos.administrator  ada@example.com  the whole platform                        b-3
             """

      {0, json, ""} = ehosctl(["role-bindings", "list", "--json"], opts)
      assert JSON.decode!(json) == %{"role_bindings" => [@listed, gone, platform]}
    end

    # EHOS's D-112 (eh-os#798): a binding a person made through their application.
    test "lists a binding granted through an application with who granted it, where and the rule",
         %{provider: provider, opts: opts} do
      granted =
        Map.merge(@listed, %{
          "id" => "b-4",
          "role" => "ledger.auditor",
          "granted_by" => "grace@example.com",
          "rule" => "ledger.clerk",
          "through" => "ledger"
        })

      # Made by an administrator in the console: who made it, and no rule.
      bound = Map.put(@listed, "granted_by", "admin@example.com")
      removed = %{granted | "id" => "b-5", "through" => nil, "granted_by" => nil}

      api(provider, "GET", "/api/v1/role-bindings", 200, %{
        "role_bindings" => [bound, granted, removed]
      })

      {0, stdout, ""} = ehosctl(["role-bindings", "list"], opts)

      assert stdout == """
              ROLE            HELD BY          WHERE              NOTE                                                                         ID
              ledger.clerk    ada@example.com  ledger in staging                                                                               #{@binding}
              ledger.auditor  ada@example.com  ledger in staging  granted by grace@example.com through ledger, under the rule of ledger.clerk  b-4
              ledger.auditor  ada@example.com  ledger in staging  granted by someone removed, under the rule of ledger.clerk                   b-5
             """

      {0, json, ""} = ehosctl(["role-bindings", "list", "--json"], opts)
      assert JSON.decode!(json) == %{"role_bindings" => [bound, granted, removed]}
    end

    # EHOS's D-161: a binding an environment template's role entry made in an ephemeral
    # environment, set by `granted_by`.
    test "names the environment template a binding came from, which gives no rule to grant by",
         %{provider: provider, opts: opts} do
      templated =
        Map.merge(@listed, %{"granted_by" => "grace@example.com", "from_template" => "previews"})

      api(provider, "GET", "/api/v1/role-bindings", 200, %{"role_bindings" => [templated]})

      {0, stdout, ""} = ehosctl(["role-bindings", "list"], opts)

      assert stdout == """
              ROLE          HELD BY          WHERE              NOTE                                                                                       ID
              ledger.clerk  ada@example.com  ledger in staging  from the environment template previews, set by grace@example.com: no right to grant roles  #{@binding}
             """

      {0, json, ""} = ehosctl(["role-bindings", "list", "--json"], opts)
      assert JSON.decode!(json) == %{"role_bindings" => [templated]}
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
      assert JSON.decode!(stdout) == %{"role_bindings" => [@listed]}

      {0, stdout, ""} =
        ehosctl(~w(role-bindings list --to ada@example.com --agent month-closer --json), opts)

      assert JSON.decode!(stdout) == %{"role_bindings" => [agents]}

      # An id in either case, as EHOS reads it.
      {0, stdout, ""} = ehosctl(~w(role-bindings list --to #{String.upcase(@ada)} --json), opts)
      assert JSON.decode!(stdout) == %{"role_bindings" => [@listed]}

      assert ehosctl(~w(role-bindings list --agent month-closer), opts) ==
               {2, "", "ehosctl: --agent needs --to. Give the email of the owner of the agent.\n"}

      # Someone who holds nothing here is said to, not that there is nothing at all.
      other = "11111111-2222-4333-8444-555555555555"

      assert ehosctl(~w(role-bindings list --to #{other}), opts) ==
               {0, "They hold no role in the places where you manage role bindings.\n", ""}
    end

    test "a binding that leaves out where it holds reads as null there",
         %{provider: provider, opts: opts} do
      platform = Map.drop(@listed, ["application", "environment"])
      application = Map.delete(@listed, "environment")

      api(provider, "GET", "/api/v1/role-bindings", 200, %{
        "role_bindings" => [platform, application]
      })

      {0, stdout, ""} = ehosctl(["role-bindings", "list"], opts)

      assert stdout == """
              ROLE          HELD BY          WHERE               NOTE  ID
              ledger.clerk  ada@example.com  the whole platform        #{@binding}
              ledger.clerk  ada@example.com  ledger                    #{@binding}
             """
    end

    # eh-os's Role bindings page says the same: another role binding includes this one.
    test "says which role binding makes a role binding add nothing, and where it holds",
         %{provider: provider, opts: opts} do
      wide = %{
        @listed
        | "id" => "b-2",
          "role" => "ehos.application_administrator",
          "environment" => nil
      }

      narrow =
        Map.merge(@listed, %{
          "id" => "b-3",
          "role" => "ehos.log_reader",
          "included_by" => Map.take(wide, ~w(id role application environment))
        })

      here = %{narrow | "id" => "b-4", "application" => "ledger", "environment" => nil}

      api(provider, "GET", "/api/v1/role-bindings", 200, %{
        "role_bindings" => [wide, narrow, here]
      })

      {0, stdout, ""} = ehosctl(["role-bindings", "list"], opts)

      assert stdout == """
              ROLE                            HELD BY          WHERE              NOTE                                                                                ID
              ehos.application_administrator  ada@example.com  ledger                                                                                                 b-2
              ehos.log_reader                 ada@example.com  ledger in staging  adds nothing: ehos.application_administrator at the application includes this role  b-3
              ehos.log_reader                 ada@example.com  ledger             adds nothing: ehos.application_administrator includes this role                     b-4
             """

      {0, json, ""} = ehosctl(["role-bindings", "list", "--json"], opts)
      assert JSON.decode!(json) == %{"role_bindings" => [wide, narrow, here]}
    end

    test "refuses a listing whose included_by is not a role binding",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/role-bindings", 200, %{
        "role_bindings" => [Map.put(@listed, "included_by", "b-2")]
      })

      assert ehosctl(["role-bindings", "list"], opts) == cannot_read(provider)
    end

    test "refuses a listing whose grant fields are not text", %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/role-bindings", 200, %{
        "role_bindings" => [Map.put(@listed, "rule", 7)]
      })

      assert ehosctl(["role-bindings", "list"], opts) == cannot_read(provider)
    end

    test "a listing refused to someone who manages no binding exits 3",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/role-bindings", 403, %{
        "error" => "forbidden",
        "message" => "Reading the role bindings needs ehos.role_binding.manage, held anywhere."
      })

      assert ehosctl(["role-bindings", "list"], opts) ==
               {3, "",
                "ehosctl: Reading the role bindings needs ehos.role_binding.manage, held " <>
                  "anywhere.\n"}
    end

    test "an answer that is not a listing is not printed as one", %{
      provider: provider,
      opts: opts
    } do
      api(provider, "GET", "/api/v1/role-bindings", 200, %{
        "role_bindings" => [%{@listed | "held_by" => "ada"}]
      })

      assert ehosctl(["role-bindings", "list"], opts) == cannot_read(provider)
    end
  end

  describe "role-bindings roles" do
    @roles [
      %{
        "name" => "ehos.application_administrator",
        "description" => "Runs an application.",
        "includes" => ["ehos.log_reader", "ehos.registrar"],
        "platform_only" => false,
        "production_only" => false,
        "capabilities" => [
          %{"name" => "ehos.application.deploy", "description" => "Deploy the application."},
          %{"name" => "ehos.secret.manage", "description" => "Manage its secrets."}
        ]
      },
      %{
        "name" => "ehos.people_reader",
        "description" => "Sees the people.",
        "includes" => [],
        "platform_only" => true,
        "production_only" => false,
        "capabilities" => [%{"name" => "ehos.people.read", "description" => "Read the people."}]
      },
      %{
        "name" => "ehos.process_owner",
        "description" => "Approves a promotion.",
        "includes" => [],
        "platform_only" => false,
        "production_only" => true,
        "capabilities" => [
          %{"name" => "ehos.release.approve", "description" => "Approve a promotion."}
        ]
      }
    ]

    test "shows each platform role in EHOS's words", %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/role-bindings/roles", 200, %{"roles" => @roles})

      {0, stdout, ""} = ehosctl(~w(role-bindings roles), opts)

      assert stdout == """
             ehos.application_administrator
             Runs an application.
             Includes ehos.log_reader, ehos.registrar.
              CAPABILITY               GRANTS
              ehos.application.deploy  Deploy the application.
              ehos.secret.manage       Manage its secrets.

             ehos.people_reader
             Sees the people.
             You can bind it only at the whole platform.
              CAPABILITY        GRANTS
              ehos.people.read  Read the people.

             ehos.process_owner
             Approves a promotion.
             In an environment, you can bind it only in production.
              CAPABILITY            GRANTS
              ehos.release.approve  Approve a promotion.
             """

      {0, json, ""} = ehosctl(~w(role-bindings roles --json), opts)
      assert JSON.decode!(json) == %{"roles" => @roles}
    end

    test "a capability's description is printed on one line, its control characters escaped",
         %{provider: provider, opts: opts} do
      [role | _] = @roles
      hostile = %{"name" => "ehos.x", "description" => "Deploy.\n\e]52;c;eA==\a"}
      role = %{role | "capabilities" => [hostile]}
      api(provider, "GET", "/api/v1/role-bindings/roles", 200, %{"roles" => [role]})

      {0, stdout, ""} = ehosctl(~w(role-bindings roles), opts)

      assert stdout =~ ~S(ehos.x      "Deploy.\n\e]52;c;eA==\a")
      refute stdout =~ "\e"
    end

    test "says a role that grants no capability, and an empty list, in words",
         %{provider: provider, opts: opts} do
      role = %{hd(@roles) | "includes" => [], "capabilities" => []}
      api(provider, "GET", "/api/v1/role-bindings/roles", 200, %{"roles" => [role]})

      assert ehosctl(~w(role-bindings roles), opts) ==
               {0,
                """
                ehos.application_administrator
                Runs an application.
                It grants no capability.
                """, ""}

      api(provider, "GET", "/api/v1/role-bindings/roles", 200, %{"roles" => []})
      assert ehosctl(~w(role-bindings roles), opts) == {0, "No platform roles.\n", ""}
    end

    test "an answer that is not a list of roles is not printed as one",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/role-bindings/roles", 200, %{
        "roles" => [Map.put(hd(@roles), "includes", "ehos.log_reader")]
      })

      assert ehosctl(~w(role-bindings roles), opts) == cannot_read(provider)
    end
  end

  describe "role-bindings bind" do
    test "binds a role to a person named by their email, in an application's environment",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/role-bindings/principals", 200, %{"principals" => @principals})

      api(provider, "POST", "/api/v1/role-bindings", 201, made(@ada))

      args = ~w(role-bindings bind ledger.clerk --to Ada@Example.com --app ledger --env staging)

      assert ehosctl(args, opts) ==
               {0, bound_said("ledger.clerk to ada@example.com in ledger in staging"), ""}

      assert posts(provider) == [
               binding_request(%{
                 "principal" => @ada,
                 "role" => "ledger.clerk",
                 "application" => "ledger",
                 "environment" => "staging"
               })
             ]
    end

    test "binds an agent named by its owner's email and its name, and an id as it is",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/role-bindings/principals", 200, %{"principals" => @principals})

      answer_bindings(provider, %{@ada => 1})

      args = ~w(role-bindings bind ehos.people_reader --to ada@example.com --agent month-closer)

      assert ehosctl(args, opts) ==
               {0,
                bound_said(
                  "ehos.people_reader to month-closer, the agent of ada@example.com at the whole " <>
                    "platform"
                ), ""}

      # D-47: binding someone who has not joined ends the links they were sent.
      assert ehosctl(~w(role-bindings bind ehos.people_reader --to #{@ada}), opts) ==
               {0,
                bound_said("ehos.people_reader to #{@ada} at the whole platform") <>
                  "  Their earlier sign-in link no longer works. They must ask for a new one.\n",
                ""}

      assert posts(provider) == [
               binding_request(%{"principal" => @agent, "role" => "ehos.people_reader"}),
               binding_request(%{"principal" => @ada, "role" => "ehos.people_reader"})
             ]

      # An id is sent as it is: only the email was looked up.
      assert FakeProvider.requests(provider, "GET /api/v1/role-bindings/principals") == [
               %{
                 path: "/api/v1/role-bindings/principals",
                 query: %{},
                 body: "",
                 content_type: nil
               }
             ]
    end

    # eh-os#703: several roles in one place, one request each, as the Bindings page binds them.
    test "binds several roles in one place, one request each, in the order given",
         %{provider: provider, opts: opts} do
      answer_bindings(provider, %{})

      args =
        ~w(role-bindings bind ledger.clerk ledger.auditor ledger.clerk --to #{@ada} --app ledger --env staging)

      assert ehosctl(args, opts) ==
               {0,
                bound_said("ledger.clerk to #{@ada} in ledger in staging") <>
                  "\n" <> bound_said("ledger.auditor to #{@ada} in ledger in staging"), ""}

      # Each role once, in the order given.
      place = %{"principal" => @ada, "application" => "ledger", "environment" => "staging"}

      assert posts(provider) == [
               binding_request(Map.put(place, "role", "ledger.clerk")),
               binding_request(Map.put(place, "role", "ledger.auditor"))
             ]

      {0, stdout, ""} = ehosctl(args ++ ["--json"], opts)

      assert JSON.decode!(stdout) == %{
               "role_bindings" => [bound("ledger.clerk"), bound("ledger.auditor")],
               "refused" => [],
               "not_asked" => []
             }
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

      assert JSON.decode!(stdout) == %{
               "role_bindings" => [bound("ehos.people_reader")],
               "refused" => [],
               "not_asked" => []
             }

      assert posts(provider) == [
               binding_request(%{"principal" => @ada, "role" => "ehos.people_reader"})
             ]
    end

    test "says who cannot be found, and refuses what names nobody, before binding",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/role-bindings/principals", 200, %{"principals" => @principals})

      assert ehosctl(~w(role-bindings bind ehos.people_reader --to bob@example.com), opts) ==
               {1, "",
                "ehosctl: No person that you can bind a role to has the email " <>
                  "bob@example.com. You can bind a role to each person who is invited and not " <>
                  "disabled. Check the email.\n"}

      args = ~w(role-bindings bind ehos.people_reader --to ada@example.com --agent other)

      assert ehosctl(args, opts) ==
               {1, "",
                "ehosctl: ada@example.com has no agent named other that you can bind a role " <>
                  "to.\n"}

      assert ehosctl(~w(role-bindings bind ehos.people_reader --to ada), opts) ==
               {2, "",
                "ehosctl: ada is not an email or an id. Give the email of a person, or the " <>
                  "email of the owner of an agent with --agent.\n"}

      assert ehosctl(~w(role-bindings bind ledger.clerk --to #{@ada} --env staging), opts) ==
               {2, "", "ehosctl: --env needs --app. Give the application with --app.\n"}

      assert posts(provider) == []
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

        assert ehosctl(~w(role-bindings bind ledger.clerk --to #{@ada}), opts) ==
                 {exit, "", "ehosctl: EHOS says #{code}.\n"}

        # Known by its code, of the kind its exit says, not only by its status (eh-os's
        # docs/refusals.md).
        assert Ehosctl.Output.code(Ehosctl.Refusal.kind(code)) == exit
      end
    end

    test "a role refused among several is said by role, the rest bound, and exits with its kind",
         %{provider: provider, opts: opts} do
      mock_bindings(provider, fn
        %{"role" => "ehos.administrator"} -> escalation()
        %{"principal" => principal, "role" => role} -> {201, made(principal, role)}
      end)

      args = ~w(role-bindings bind ehos.administrator ehos.people_reader --to #{@ada})

      # What was bound on stdout, what was refused on stderr.
      assert ehosctl(args, opts) ==
               {3, bound_said("ehos.people_reader to #{@ada} at the whole platform"),
                "ehosctl: ehos.administrator: You do not hold what it grants.\n"}

      assert posts(provider) == [
               binding_request(%{"principal" => @ada, "role" => "ehos.administrator"}),
               binding_request(%{"principal" => @ada, "role" => "ehos.people_reader"})
             ]

      # As JSON, both, with the refusal's kind, and the same exit code.
      {3, stdout, ""} = ehosctl(args ++ ["--json"], opts)

      assert JSON.decode!(stdout) == %{
               "role_bindings" => [bound("ehos.people_reader")],
               "refused" => [
                 %{
                   "role" => "ehos.administrator",
                   "kind" => "refused",
                   "refusal" => "You do not hold what it grants.",
                   "code" => "escalation"
                 }
               ],
               "not_asked" => []
             }
    end

    test "roles are not asked once being signed out would refuse every one",
         %{provider: provider, opts: opts} do
      api(provider, "POST", "/api/v1/role-bindings", 401, %{
        "error" => "expired",
        "message" => "Your sign-in has expired."
      })

      assert ehosctl(~w(role-bindings bind ehos.people_reader ehos.log_reader --to #{@ada}), opts) ==
               {4, "",
                """
                ehosctl: ehos.people_reader: Your sign-in has expired.
                ehos.log_reader: not sent to EHOS.
                """}

      assert posts(provider) == [
               binding_request(%{"principal" => @ada, "role" => "ehos.people_reader"})
             ]
    end

    test "a run that stops after a refusal exits with what stopped it, and says what was not asked",
         %{provider: provider, opts: opts} do
      mock_bindings(provider, fn
        %{"role" => "ehos.administrator"} ->
          escalation()

        %{"principal" => principal, "role" => "ehos.people_reader" = role} ->
          {201, made(principal, role)}

        _later ->
          expired()
      end)

      args =
        ~w(role-bindings bind ehos.administrator ehos.people_reader ehos.log_reader ehos.registrar --to #{@ada} --json)

      {4, stdout, ""} = ehosctl(args, opts)

      assert JSON.decode!(stdout) == %{
               "role_bindings" => [bound("ehos.people_reader")],
               "refused" => [
                 %{
                   "role" => "ehos.administrator",
                   "kind" => "refused",
                   "refusal" => "You do not hold what it grants.",
                   "code" => "escalation"
                 },
                 %{
                   "role" => "ehos.log_reader",
                   "kind" => "not_signed_in",
                   "refusal" => "Your sign-in has expired.",
                   "code" => "expired"
                 }
               ],
               "not_asked" => ["ehos.registrar"]
             }
    end

    test "the last role's sign-in refusal decides the exit code, after an earlier refusal",
         %{provider: provider, opts: opts} do
      mock_bindings(provider, fn
        %{"role" => "ehos.administrator"} -> escalation()
        _last -> expired()
      end)

      assert ehosctl(
               ~w(role-bindings bind ehos.administrator ehos.people_reader --to #{@ada}),
               opts
             ) ==
               {4, "",
                """
                ehosctl: ehos.administrator: You do not hold what it grants.
                ehos.people_reader: Your sign-in has expired.
                """}
    end

    test "an option bind does not take is not taken for a role", %{provider: provider, opts: opts} do
      assert ehosctl(~w(role-bindings bind ledger.clerk --to #{@ada} --evn staging), opts) ==
               {2, "",
                "ehosctl: --evn is not an option of bind.\n" <>
                  "What to do:\n" <>
                  "  See its options:\n" <>
                  "  ehosctl role-bindings bind --help\n"}

      assert posts(provider) == []
    end

    test "a binding EHOS answers of another role or principal is not taken for the one asked",
         %{provider: provider, opts: opts} do
      for answer <- [made(@agent), made(@ada, "ledger.auditor")] do
        api(provider, "POST", "/api/v1/role-bindings", 201, answer)

        assert ehosctl(~w(role-bindings bind ledger.clerk --to #{@ada}), opts) ==
                 not_as_asked(provider)
      end
    end
  end

  describe "role-bindings unbind" do
    test "unbinds a binding by its id, in either case", %{provider: provider, opts: opts} do
      api(provider, "DELETE", "/api/v1/role-bindings/#{String.upcase(@binding)}", 200, %{
        "role_binding" => %{"id" => @binding, "role" => "ledger.clerk"}
      })

      assert ehosctl(["role-bindings", "unbind", String.upcase(@binding)], opts) ==
               {0, "Removed the role binding ledger.clerk, #{@binding}.\n", ""}
    end

    test "an unbinding EHOS says it did of another binding is not taken for this one",
         %{provider: provider, opts: opts} do
      api(provider, "DELETE", "/api/v1/role-bindings/#{@binding}", 200, %{
        "role_binding" => %{"id" => "another", "role" => "ledger.clerk"}
      })

      assert ehosctl(["role-bindings", "unbind", @binding], opts) == not_as_asked(provider)
    end
  end

  # eh-os D-203: a role binding of a data role in a production environment ends, and has a reason.
  describe "role-bindings bind, to a production environment's data" do
    @ends "2026-11-28T16:00:00Z"
    @reason "to check the invoices of ticket 4711"
    @production ~w(--to #{@ada} --app office --env production)

    # Before a data role is bound in an environment, its role binding there is looked for: none.
    setup %{provider: provider} do
      stub_now(~U[2026-11-28 12:00:00Z])
      api(provider, "GET", "/api/v1/role-bindings", 200, %{"role_bindings" => []})
    end

    test "sends --for in seconds and --reason, and says when the role binding ends and why",
         %{provider: provider, opts: opts} do
      answer_ending(provider)

      args =
        ~w(role-bindings bind ehos.data_reader) ++
          @production ++ ["--for", "4h", "--reason", @reason]

      assert ehosctl(args, opts) ==
               {0,
                "✓ Bound ehos.data_reader to #{@ada} in office in production.\n" <>
                  "  Role binding   #{@binding}\n" <>
                  "  Ends           28 November 2026, 16:00 UTC\n" <>
                  "  Reason         #{@reason}\n", ""}

      {0, json, ""} = ehosctl(args ++ ["--json"], opts)

      assert JSON.decode!(json) == %{
               "role_binding" =>
                 Map.merge(bound("ehos.data_reader"), %{
                   "expires_at" => @ends,
                   "reason" => @reason
                 })
             }

      {0, _said, ""} =
        ehosctl(
          ~w(role-bindings bind ehos.data_writer) ++
            @production ++ ["--for", "7d", "--reason", @reason],
          opts
        )

      assert Enum.map(posts(provider), &Map.take(&1.body, ["duration", "reason"])) == [
               %{"duration" => 14_400, "reason" => @reason},
               %{"duration" => 14_400, "reason" => @reason},
               %{"duration" => 604_800, "reason" => @reason}
             ]
    end

    test "without --for, sends no duration, and EHOS gives the installation's default",
         %{provider: provider, opts: opts} do
      answer_ending(provider)

      {0, _said, ""} =
        ehosctl(
          ~w(role-bindings bind ehos.data_reader) ++ @production ++ ["--reason", @reason],
          opts
        )

      assert [%{body: body}] = posts(provider)

      assert body == %{
               "principal" => @ada,
               "role" => "ehos.data_reader",
               "application" => "office",
               "environment" => "production",
               "reason" => @reason
             }
    end

    test "refuses a --for that is not hours or days, before it asks EHOS", %{
      provider: provider,
      opts: opts
    } do
      for duration <- ["4", "30m", "0h", "1.5h", "h", "-4h"] do
        assert ehosctl(
                 ~w(role-bindings bind ehos.data_reader) ++ @production ++ ["--for=" <> duration],
                 opts
               ) ==
                 {2, "",
                  "ehosctl: --for #{duration} is not a duration in hours or days. Give it as 4h " <>
                    "or 7d, for example.\n"}
      end

      assert posts(provider) == []
    end

    test "at a terminal, asks for the reason EHOS needs, once for every role that needs one",
         %{provider: provider, opts: opts} do
      answer_ending(provider)
      at_terminal()
      expect(Ehosctl.TerminalMock, :gets, fn "" -> "  #{@reason}\n" end)

      args = ~w(role-bindings bind ehos.data_reader ehos.data_writer) ++ @production

      assert ehosctl(args, opts) ==
               {0, ending_said("ehos.data_reader") <> "\n" <> ending_said("ehos.data_writer"),
                installation(provider) <> asked("ehos.data_reader")}

      # Each role is sent as given, and again with the reason typed once EHOS says it needs one.
      assert Enum.map(posts(provider), &{&1.body["role"], &1.body["reason"]}) == [
               {"ehos.data_reader", nil},
               {"ehos.data_reader", @reason},
               {"ehos.data_writer", nil},
               {"ehos.data_writer", @reason}
             ]
    end

    test "at a terminal, asks again for a role after EHOS refused the reason typed before",
         %{provider: provider, opts: opts} do
      answer_ending(provider)
      at_terminal()
      expect(Ehosctl.TerminalMock, :gets, 2, fn "" -> "short\n" end)

      stub_env(%{"NO_COLOR" => "1"})

      invalid =
        "The reason is not valid. Write it on one line, from 10 to 500 characters, with no " <>
          "control or invisible characters."

      assert ehosctl(
               ~w(role-bindings bind ehos.data_reader ehos.data_writer) ++ @production,
               opts
             ) ==
               {2, "",
                installation(provider) <>
                  asked("ehos.data_reader") <>
                  asked("ehos.data_writer") <>
                  "ehosctl: ehos.data_reader: #{invalid}\nehos.data_writer: #{invalid}\n"}

      assert Enum.map(posts(provider), &{&1.body["role"], &1.body["reason"]}) == [
               {"ehos.data_reader", nil},
               {"ehos.data_reader", "short"},
               {"ehos.data_writer", nil},
               {"ehos.data_writer", "short"}
             ]
    end

    test "at a terminal, keeps a typed reason for the next role after another refusal",
         %{provider: provider, opts: opts} do
      at_terminal()
      stub_env(%{"NO_COLOR" => "1"})
      expect(Ehosctl.TerminalMock, :gets, fn "" -> "#{@reason}\n" end)

      # EHOS checks what the binder holds after the reason: the first role is refused for it.
      mock_bindings(provider, fn
        %{"role" => "ehos.data_reader", "reason" => _reason} -> escalation()
        %{"reason" => reason} = body -> {201, ending_made(body, reason)}
        %{"role" => role} -> reason_required(role)
      end)

      assert ehosctl(
               ~w(role-bindings bind ehos.data_reader ehos.data_writer) ++ @production,
               opts
             ) ==
               {3, ending_said("ehos.data_writer"),
                installation(provider) <>
                  asked("ehos.data_reader") <>
                  "ehosctl: ehos.data_reader: You do not hold what it grants.\n"}

      assert Enum.map(posts(provider), &{&1.body["role"], &1.body["reason"]}) == [
               {"ehos.data_reader", nil},
               {"ehos.data_reader", @reason},
               {"ehos.data_writer", nil},
               {"ehos.data_writer", @reason}
             ]
    end

    test "at a terminal, asks for the reason when --reason is blank", %{
      provider: provider,
      opts: opts
    } do
      answer_ending(provider)
      at_terminal()
      expect(Ehosctl.TerminalMock, :gets, fn "" -> "#{@reason}\n" end)

      assert ehosctl(
               ~w(role-bindings bind ehos.data_reader) ++ @production ++ ["--reason", " "],
               opts
             ) ==
               {0, ending_said("ehos.data_reader"),
                installation(provider) <> asked("ehos.data_reader")}

      assert Enum.map(posts(provider), & &1.body["reason"]) == [nil, @reason]
    end

    test "without a terminal, or with no reason typed, says which flag gives the reason",
         %{provider: provider, opts: opts} do
      answer_ending(provider)

      said =
        "Give a reason. A role binding of ehos.data_reader in a production environment " <>
          "needs one. Give it with --reason. At a terminal, ehosctl asks for it."

      args = ~w(role-bindings bind ehos.data_reader) ++ @production
      assert ehosctl(args, opts) == {2, "", "ehosctl: #{said}\n"}

      {2, "", json} = ehosctl(args ++ ["--json"], opts)

      assert JSON.decode!(json) == %{
               "error" => %{"code" => "reason_required", "kind" => "invalid", "message" => said}
             }

      at_terminal()
      stub_env(%{"NO_COLOR" => "1"})
      expect(Ehosctl.TerminalMock, :gets, fn "" -> " \n" end)

      assert ehosctl(args, opts) ==
               {2, "",
                installation(provider) <> asked("ehos.data_reader") <> "ehosctl: #{said}\n"}

      assert length(posts(provider)) == 3
    end

    test "says a role binding as bound when its end passed while the person typed the reason",
         %{provider: provider, opts: opts} do
      answer_ending(provider)
      at_terminal()
      {:ok, clock} = Agent.start_link(fn -> ~U[2026-11-28 12:00:00Z] end)
      stub(Ehosctl.ClockMock, :now, fn -> Agent.get(clock, & &1) end)

      # The person answers after the end that the listing gave, 12:01.
      expect(Ehosctl.TerminalMock, :gets, fn "" ->
        Agent.update(clock, fn _now -> ~U[2026-11-28 12:02:00Z] end)
        "#{@reason}\n"
      end)

      api(provider, "GET", "/api/v1/role-bindings", 200, %{
        "role_bindings" => [listed_ending("ehos.data_reader", "2026-11-28T12:01:00Z")]
      })

      assert ehosctl(~w(role-bindings bind ehos.data_reader) ++ @production, opts) ==
               {0, ending_said("ehos.data_reader"),
                installation(provider) <> asked("ehos.data_reader")}
    end

    test "says a role binding bound again as extended or shortened to its new end",
         %{provider: provider, opts: opts} do
      answer_ending(provider)

      for {before, said} <- [
            {"2026-11-28T14:00:00Z", "Extended the role binding ehos.data_reader of"},
            {"2026-11-29T14:00:00Z", "Shortened the role binding ehos.data_reader of"}
          ] do
        api(provider, "GET", "/api/v1/role-bindings", 200, %{
          "role_bindings" => [listed_ending("ehos.data_reader", before)]
        })

        assert ehosctl(
                 ~w(role-bindings bind ehos.data_reader) ++ @production ++ ["--reason", @reason],
                 opts
               ) == {0, ending_said("ehos.data_reader", said), ""}
      end

      # A role binding of another role, held by someone else, or ended, is not one bound again.
      bob = "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"

      for listed <- [
            listed_ending("ehos.data_writer", "2026-11-28T14:00:00Z"),
            put_in(
              listed_ending("ehos.data_reader", "2026-11-28T14:00:00Z"),
              ["held_by", "id"],
              bob
            ),
            listed_ending("ehos.data_reader", "2026-11-28T11:00:00Z")
          ] do
        api(provider, "GET", "/api/v1/role-bindings", 200, %{"role_bindings" => [listed]})

        assert ehosctl(
                 ~w(role-bindings bind ehos.data_reader) ++ @production ++ ["--reason", @reason],
                 opts
               ) == {0, ending_said("ehos.data_reader"), ""}
      end
    end

    test "reads the role bindings there once for the command, and only for a data role",
         %{provider: provider, opts: opts} do
      answer_ending(provider)

      {0, _said, ""} =
        ehosctl(
          ~w(role-bindings bind ehos.data_reader ehos.data_writer) ++
            @production ++ ["--reason", @reason],
          opts
        )

      assert length(FakeProvider.requests(provider, "GET /api/v1/role-bindings")) == 1

      answer_bindings(provider, %{})
      {0, _said, ""} = ehosctl(~w(role-bindings bind ledger.clerk) ++ @production, opts)

      assert length(FakeProvider.requests(provider, "GET /api/v1/role-bindings")) == 1
    end

    test "sends --for and --reason only with a data role, and refuses them with no data role",
         %{provider: provider, opts: opts} do
      answer_ending(provider)

      {0, said, ""} =
        ehosctl(
          ~w(role-bindings bind ehos.data_reader ledger.clerk) ++
            @production ++ ["--for", "4h", "--reason", @reason],
          opts
        )

      place = %{"principal" => @ada, "application" => "office", "environment" => "production"}

      assert posts(provider) == [
               binding_request(
                 Map.merge(place, %{
                   "role" => "ehos.data_reader",
                   "duration" => 14_400,
                   "reason" => @reason
                 })
               ),
               binding_request(Map.put(place, "role", "ledger.clerk"))
             ]

      assert said ==
               ending_said("ehos.data_reader") <>
                 "\n" <>
                 bound_said("ledger.clerk to #{@ada} in office in production")

      for terms <- [["--for", "4h"], ["--reason", @reason]] do
        assert ehosctl(~w(role-bindings bind ledger.clerk) ++ @production ++ terms, opts) ==
                 {2, "",
                  "ehosctl: --for and --reason are only for a role binding of ehos.data_reader " <>
                    "or ehos.data_writer in a production environment. Leave them out.\n"}
      end

      assert length(posts(provider)) == 2
    end

    test "prints EHOS's refusals of the end and the reason, with the flag to change, and exits 2",
         %{provider: provider, opts: opts} do
      # The refusals of eh-os's controller, for a data role: in production, and in staging, where
      # a role binding has no end.
      for {code, env, message, added} <- [
            {"invalid_reason", "production",
             "The reason is not valid. Write it on one line, from 10 to 500 characters, with no " <>
               "control or invisible characters.", ""},
            {"invalid_duration", "production",
             "The duration is not valid. Give a whole number of seconds from 3600 (1 hour) to " <>
               "604800, the longest time the installation allows.",
             " Give --for in hours or days, from 1h up to that time, such as 4h or 7d."},
            {"not_expiring", "staging",
             "A role binding of ehos.data_reader there has no end and no reason. Bind it " <>
               "without a duration and without a reason.", " Leave out --for and --reason."}
          ] do
        api(provider, "POST", "/api/v1/role-bindings", 422, %{
          "error" => code,
          "message" => message
        })

        assert ehosctl(
                 ~w(role-bindings bind ehos.data_reader --to #{@ada} --app office --env #{env} --for 9d --reason short),
                 opts
               ) == {2, "", "ehosctl: #{message}#{added}\n"}
      end
    end
  end

  describe "role-bindings list, of a production environment's data" do
    test "shows the end and the reason of each role binding that has them, and one that ended",
         %{provider: provider, opts: opts} do
      stub_now(~U[2026-11-28 12:00:00Z])

      reading =
        Map.merge(@listed, %{
          "id" => "b-6",
          "role" => "ehos.data_reader",
          "application" => "office",
          "environment" => "production",
          "expires_at" => "2026-11-28T16:00:00Z",
          "reason" => "to check the invoices of ticket 4711"
        })

      ended = %{reading | "id" => "b-7", "expires_at" => "2026-11-28T11:00:00Z"}

      api(provider, "GET", "/api/v1/role-bindings", 200, %{
        "role_bindings" => [@listed, reading, ended]
      })

      {0, stdout, ""} = ehosctl(["role-bindings", "list"], opts)

      assert stdout == """
              ROLE              HELD BY          WHERE                 ENDS                         REASON                                NOTE                   ID
              ledger.clerk      ada@example.com  ledger in staging     <none>                       <none>                                                       #{@binding}
              ehos.data_reader  ada@example.com  office in production  28 November 2026, 16:00 UTC  to check the invoices of ticket 4711                         b-6
              ehos.data_reader  ada@example.com  office in production  28 November 2026, 11:00 UTC  to check the invoices of ticket 4711  ended: grants nothing  b-7
             """

      {0, json, ""} = ehosctl(["role-bindings", "list", "--json"], opts)
      assert JSON.decode!(json) == %{"role_bindings" => [@listed, reading, ended]}
    end
  end

  # Answers each binding with `answer`, given the body it was sent, decoded.
  defp mock_bindings(provider, answer) do
    FakeProvider.stub_api(provider, "POST", "/api/v1/role-bindings", fn %{body: body} ->
      answer.(JSON.decode!(body))
    end)
  end

  # Answers each binding as EHOS would: of the role to the principal asked for, ending the
  # sign-in links of a person who has not joined, and none of an agent's, which has none.
  defp answer_bindings(provider, links) do
    mock_bindings(provider, fn %{"principal" => principal, "role" => role} ->
      {201, made(principal, role, Map.get(links, principal, 0))}
    end)
  end

  # Answers each binding as EHOS answers one of a data role in a production environment: with an
  # end and the reason it was sent, and `reason_required` when it was sent none.
  defp answer_ending(provider) do
    mock_bindings(provider, fn
      %{"reason" => reason} when byte_size(reason) < 10 ->
        {422,
         %{
           "error" => "invalid_reason",
           "message" =>
             "The reason is not valid. Write it on one line, from 10 to 500 characters, with no " <>
               "control or invisible characters."
         }}

      %{"reason" => reason} = body ->
        {201, ending_made(body, reason)}

      %{"role" => role} = body when role not in ["ehos.data_reader", "ehos.data_writer"] ->
        {201, made(body["principal"], role)}

      %{"role" => role} ->
        reason_required(role)
    end)
  end

  # A role binding of a data role in production as EHOS answers it, with its end and `reason`.
  defp ending_made(body, reason),
    do: %{
      "role_binding" =>
        Map.merge(made(body["principal"], body["role"])["role_binding"], %{
          "expires_at" => @ends,
          "reason" => reason
        })
    }

  defp reason_required(role),
    do:
      {422,
       %{
         "error" => "reason_required",
         "message" =>
           "Give a reason. A role binding of #{role} in a production environment needs one."
       }}

  # A role binding of `role` to Ada in office's production that ends at `ends`, as listed.
  defp listed_ending(role, ends),
    do:
      Map.merge(@listed, %{
        "role" => role,
        "application" => "office",
        "environment" => "production",
        "expires_at" => ends,
        "reason" => "an earlier reason"
      })

  # What `bind` says of a role binding to production data that `answer_ending/1` made.
  defp ending_said(role, said \\ nil) do
    "✓ #{said || "Bound #{role} to"} #{@ada} in office in production.\n" <>
      "  Role binding   #{@binding}\n" <>
      "  Ends           28 November 2026, 16:00 UTC\n" <>
      "  Reason         #{@reason}\n"
  end

  defp at_terminal do
    stub(Ehosctl.TerminalMock, :input_terminal?, fn -> true end)
    stub(Ehosctl.TerminalMock, :error_terminal?, fn -> true end)
  end

  # At a terminal, which installation is said first.
  defp installation(provider), do: "Installation: local (#{provider.issuer})\n"

  defp asked(role),
    do:
      "A role binding of #{role} in a production environment needs a reason. EHOS keeps it " <>
        "with the role binding.\nReason: "

  defp escalation,
    do: {403, %{"error" => "escalation", "message" => "You do not hold what it grants."}}

  defp expired, do: {401, %{"error" => "expired", "message" => "Your sign-in has expired."}}

  defp made(principal, role \\ "ledger.clerk", links \\ 0),
    do: %{
      "role_binding" => %{
        "id" => @binding,
        "role" => role,
        "principal" => principal,
        "sign_in_links_ended" => links
      }
    }

  # A binding of `role` to Ada, as --json prints it.
  defp bound(role), do: made(@ada, role)["role_binding"]

  # The bindings sent, oldest first, each body decoded.
  defp posts(provider), do: json_requests(provider, "POST /api/v1/role-bindings")

  defp binding_request(body), do: json_request("/api/v1/role-bindings", body)

  defp cannot_read(provider),
    do: {1, "", "ehosctl: #{provider.issuer} answered with something ehosctl cannot read.\n"}

  defp not_as_asked(provider),
    do:
      {1, "",
       "ehosctl: #{provider.issuer} answered with something ehosctl cannot read. It answered " <>
         "that something was done, but not as what was asked.\nWhat to do:\n  See what was done:\n  ehosctl role-bindings list --installation local\n"}

  # What `bind` says of a role binding `what`, with its id.
  defp bound_said(what), do: "✓ Bound #{what}.\n  Role binding   #{@binding}\n"
end
