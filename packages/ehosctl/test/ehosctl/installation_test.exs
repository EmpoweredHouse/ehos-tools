defmodule Ehosctl.InstallationTest do
  # `ehosctl installation` (eh-os#349, ehos-tools#91): the reading the console's Installation page
  # shows, from `GET /api/v1/installation`.
  use Ehosctl.SignInCase

  doctest Ehosctl.Installation

  # The local k3d cluster's reading, as eh-os answered it on 10 October 2026.
  @reading %{
    "installation" => %{
      "name" => "ehos",
      "provider" => "k3d",
      "region" => nil,
      "size" => nil,
      "console" => "https://ehos.localhost"
    },
    "ehos" => %{
      "version" => "0.14.0",
      "commit" => "db57a37e4f1c9a2b8d3e6f7a1b2c3d4e5f6a7b8c",
      "installed_at" => "2026-10-20T09:30:00.000000Z"
    },
    "four_eyes" => %{"on" => false, "since" => "2026-10-20T12:00:58.558830Z"},
    "nodes" => [
      %{
        "name" => "k3d-ehos-server-0",
        "capacity" => %{"cpu_millicores" => 14_000, "memory_bytes" => 8_217_473_024},
        "allocatable" => %{"cpu_millicores" => 14_000, "memory_bytes" => 8_217_473_024},
        "used" => %{"cpu_millicores" => 1427, "memory_bytes" => 4_804_644_864}
      }
    ],
    "quotas" => "available",
    "usage" => "available",
    "environments" => [
      %{
        "name" => "production",
        "quota" => %{
          "cpu_requests_millicores" => 2000,
          "memory_requests_bytes" => 4_294_967_296,
          "memory_limits_bytes" => 8_589_934_592,
          "pods" => 20
        },
        "requested" => %{
          "cpu_requests_millicores" => 200,
          "memory_requests_bytes" => 536_870_912,
          "memory_limits_bytes" => 1_073_741_824,
          "pods" => 2
        },
        "used" => %{"cpu_millicores" => 13, "memory_bytes" => 551_550_976},
        "applications" => [
          %{
            "name" => "ledger",
            "pods" => 1,
            "used" => %{"cpu_millicores" => 6, "memory_bytes" => 275_775_488}
          }
        ]
      },
      %{
        "name" => "review-7",
        "quota" => nil,
        "requested" => nil,
        "used" => %{"cpu_millicores" => 0, "memory_bytes" => 0},
        "applications" => []
      }
    ]
  }

  # `@reading` as `ehosctl installation` prints it.
  @printed """
  ehos on k3d, at https://ehos.localhost

  EHOS 0.14.0, commit db57a37e4f1c9a2b8d3e6f7a1b2c3d4e5f6a7b8c, installed 2026-10-20 09:30 UTC

  Four eyes on promotions: off, since 2026-10-20T12:00:58.558830Z. The person who deployed or asked can approve. EHOS records it as a self-approval.

   NODE               CPU USED            MEMORY USED         CAPACITY
   k3d-ehos-server-0  1.43 CPU of 14 CPU  4.5 GiB of 7.7 GiB  14 CPU, 7.7 GiB

   ENVIRONMENT  CPU USED  MEMORY USED  CPU REQUESTED      MEMORY REQUESTED  PODS
   production   13m CPU   526 MiB      200m CPU of 2 CPU  512 MiB of 4 GiB  2 of 20
   review-7     0m CPU    0 MiB        no quota yet       no quota yet      no quota yet
  The quota limits what the pods of an environment request. A pod can use more than it requested, up to its limit.

   APPLICATION  ENVIRONMENT  PODS  CPU USED  MEMORY USED
   ledger       production   1     6m CPU    263 MiB
  """

  @ehos_line "EHOS 0.14.0, commit db57a37e4f1c9a2b8d3e6f7a1b2c3d4e5f6a7b8c, installed 2026-10-20 " <>
               "09:30 UTC\n"

  @four_eyes_line "Four eyes on promotions: off, since 2026-10-20T12:00:58.558830Z. The " <>
                    "person who deployed or asked can approve. EHOS records it as a " <>
                    "self-approval.\n"

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    :ok
  end

  test "prints the installation, its nodes, and each environment's use against its quota",
       %{provider: provider, opts: opts} do
    serve(provider, @reading)

    assert ehosctl(["installation"], opts) == {0, @printed, ""}
  end

  test "--json gives the reading as EHOS answered it, without what it does not know",
       %{provider: provider, opts: opts} do
    serve(
      provider,
      @reading
      |> put_in(["installation", "extra"], "dropped")
      |> put_in(["four_eyes", "extra"], "dropped")
    )

    {0, json, ""} = ehosctl(["installation", "--json"], opts)
    assert JSON.decode!(json) == @reading
  end

  test "reads an EHOS that does not say which it is, or when it was installed",
       %{provider: provider, opts: opts} do
    serve(provider, Map.delete(@reading, "ehos"))

    assert ehosctl(["installation"], opts) ==
             {0, String.replace(@printed, @ehos_line <> "\n", ""), ""}

    {0, json, ""} = ehosctl(["installation", "--json"], opts)
    assert JSON.decode!(json) == %{@reading | "ehos" => nil}

    serve(provider, %{
      @reading
      | "ehos" => %{"version" => "0.14.0-dev", "commit" => nil, "installed_at" => nil}
    })

    assert ehosctl(["installation"], opts) ==
             {0,
              String.replace(
                @printed,
                @ehos_line,
                "EHOS 0.14.0-dev, with no record of when it was installed\n"
              ), ""}
  end

  # eh-os D-128, eh-os#749: on, without a change recorded yet; and none from an EHOS before it.
  test "says whether four eyes holds, and nothing from an EHOS that does not",
       %{provider: provider, opts: opts} do
    serve(provider, %{@reading | "four_eyes" => %{"on" => true, "since" => nil}})

    assert ehosctl(["installation"], opts) ==
             {0,
              String.replace(
                @printed,
                @four_eyes_line,
                "Four eyes on promotions: on. The person who deployed or asked cannot " <>
                  "approve.\n"
              ), ""}

    # `since` left out is said as null, as every key the contract names.
    serve(provider, %{@reading | "four_eyes" => %{"on" => true}})
    {0, json, ""} = ehosctl(["installation", "--json"], opts)
    assert JSON.decode!(json) == %{@reading | "four_eyes" => %{"on" => true, "since" => nil}}

    serve(provider, Map.delete(@reading, "four_eyes"))

    assert ehosctl(["installation"], opts) ==
             {0, String.replace(@printed, @four_eyes_line <> "\n", ""), ""}

    {0, json, ""} = ehosctl(["installation", "--json"], opts)
    assert JSON.decode!(json) == %{@reading | "four_eyes" => nil}
  end

  test "says what EHOS could not read, and prints the rest", %{provider: provider, opts: opts} do
    unread =
      @reading
      |> Map.merge(%{"nodes" => nil, "quotas" => "unavailable", "usage" => "unavailable"})
      |> Map.put("environments", [
        %{
          "name" => "production",
          "quota" => nil,
          "requested" => nil,
          "used" => nil,
          "applications" => []
        }
      ])
      |> put_in(["installation", "size"], "4 OCPUs, 24 GB")

    serve(provider, unread)

    assert ehosctl(["installation"], opts) ==
             {0,
              """
              ehos on k3d, at https://ehos.localhost
              Size: 4 OCPUs, 24 GB

              EHOS 0.14.0, commit db57a37e4f1c9a2b8d3e6f7a1b2c3d4e5f6a7b8c, installed 2026-10-20 09:30 UTC

              Four eyes on promotions: off, since 2026-10-20T12:00:58.558830Z. The person who deployed or asked can approve. EHOS records it as a self-approval.

              EHOS could not list the nodes of the cluster.
              EHOS could not list the quotas of the environments.
              The metrics API of the cluster did not answer, so ehosctl does not show the use now. A cluster without metrics-server has no metrics API.

               ENVIRONMENT  CPU USED   MEMORY USED  CPU REQUESTED  MEMORY REQUESTED  PODS
               production   not known  not known    not known      not known         not known
              The quota limits what the pods of an environment request. A pod can use more than it requested, up to its limit.

              No pods of applications run, or EHOS does not know their use. An application shows here when its pods run.
              """, ""}
  end

  test "shows a name a terminal would act on as text, not as it is",
       %{provider: provider, opts: opts} do
    serve(provider, put_in(@reading, ["installation", "name"], "ehos\e[2J"))

    assert ehosctl(["installation"], opts) ==
             {0, String.replace(@printed, "ehos on k3d", ~S("ehos\e[2J" on k3d)), ""}
  end

  # The review of ehos-tools#91: what EHOS may add later, or leave out, keeps the reading readable.
  test "leaves out a limit it does not know, and keeps one shape under --json",
       %{provider: provider, opts: opts} do
    reading =
      @reading
      |> put_in(["environments", Access.at(0), "quota", "cpu_limits_millicores"], 4000)
      |> update_in(["installation"], &Map.drop(&1, ["region", "size"]))
      |> update_in(["nodes", Access.at(0)], &Map.delete(&1, "used"))

    serve(provider, reading)

    {0, json, ""} = ehosctl(["installation", "--json"], opts)
    assert JSON.decode!(json) == put_in(@reading, ["nodes", Access.at(0), "used"], nil)
  end

  test "says a limit the quota does not set, and what is not known of a node",
       %{provider: provider, opts: opts} do
    reading =
      @reading
      |> update_in(["environments", Access.at(0), "quota"], &Map.delete(&1, "pods"))
      |> update_in(
        ["environments", Access.at(0), "requested"],
        &Map.delete(&1, "memory_requests_bytes")
      )
      |> put_in(["nodes", Access.at(0), "used"], nil)

    serve(provider, reading)

    assert ehosctl(["installation"], opts) ==
             {0,
              """
              ehos on k3d, at https://ehos.localhost

              EHOS 0.14.0, commit db57a37e4f1c9a2b8d3e6f7a1b2c3d4e5f6a7b8c, installed 2026-10-20 09:30 UTC

              Four eyes on promotions: off, since 2026-10-20T12:00:58.558830Z. The person who deployed or asked can approve. EHOS records it as a self-approval.

               NODE               CPU USED   MEMORY USED  CAPACITY
               k3d-ehos-server-0  not known  not known    14 CPU, 7.7 GiB

               ENVIRONMENT  CPU USED  MEMORY USED  CPU REQUESTED      MEMORY REQUESTED  PODS
               production   13m CPU   526 MiB      200m CPU of 2 CPU  ? of 4 GiB        no limit
               review-7     0m CPU    0 MiB        no quota yet       no quota yet      no quota yet
              The quota limits what the pods of an environment request. A pod can use more than it requested, up to its limit.

               APPLICATION  ENVIRONMENT  PODS  CPU USED  MEMORY USED
               ledger       production   1     6m CPU    263 MiB
              """, ""}
  end

  test "says where it runs in as many words as it was told", %{provider: provider, opts: opts} do
    for {description, said} <- [
          {%{"name" => nil, "provider" => nil}, "This installation, at https://ehos.localhost"},
          {%{"provider" => nil, "region" => "eu-frankfurt-1"},
           "ehos in eu-frankfurt-1, at https://ehos.localhost"},
          {%{"provider" => "oci", "region" => "eu-frankfurt-1"},
           "ehos on oci, eu-frankfurt-1, at https://ehos.localhost"}
        ] do
      serve(provider, update_in(@reading, ["installation"], &Map.merge(&1, description)))

      assert ehosctl(["installation"], opts) ==
               {0, String.replace(@printed, "ehos on k3d, at https://ehos.localhost", said), ""}
    end
  end

  test "says when there are no nodes, environments or applications",
       %{provider: provider, opts: opts} do
    serve(provider, %{@reading | "nodes" => [], "environments" => []})

    assert ehosctl(["installation"], opts) ==
             {0,
              """
              ehos on k3d, at https://ehos.localhost

              EHOS 0.14.0, commit db57a37e4f1c9a2b8d3e6f7a1b2c3d4e5f6a7b8c, installed 2026-10-20 09:30 UTC

              Four eyes on promotions: off, since 2026-10-20T12:00:58.558830Z. The person who deployed or asked can approve. EHOS records it as a self-approval.

              The cluster has no nodes.

              No environments. An environment shows here when a person creates one.

              No pods of applications run, or EHOS does not know their use. An application shows here when its pods run.
              """, ""}
  end

  test "gives an unread reading under --json as EHOS said it", %{provider: provider, opts: opts} do
    unread = %{@reading | "nodes" => nil, "quotas" => "unavailable", "usage" => "unavailable"}
    serve(provider, unread)

    {0, json, ""} = ehosctl(["installation", "--json"], opts)
    assert JSON.decode!(json) == unread
  end

  test "shows every name a terminal would act on as text", %{provider: provider, opts: opts} do
    escape = "\e]52;c;aGk=\a"

    reading =
      @reading
      |> put_in(["installation", "provider"], "k3d" <> escape)
      |> put_in(["installation", "console"], "https://x" <> escape)
      |> put_in(["nodes", Access.at(0), "name"], "node" <> escape)
      |> put_in(["environments", Access.at(0), "name"], "prod" <> escape)
      |> put_in(
        ["environments", Access.at(0), "applications", Access.at(0), "name"],
        "app" <> escape
      )

    serve(provider, reading)

    assert ehosctl(["installation"], opts) ==
             {0,
              ~S"""
              ehos on "k3d\e]52;c;aGk=\a", at "https://x\e]52;c;aGk=\a"

              EHOS 0.14.0, commit db57a37e4f1c9a2b8d3e6f7a1b2c3d4e5f6a7b8c, installed 2026-10-20 09:30 UTC

              Four eyes on promotions: off, since 2026-10-20T12:00:58.558830Z. The person who deployed or asked can approve. EHOS records it as a self-approval.

               NODE                  CPU USED            MEMORY USED         CAPACITY
               "node\e]52;c;aGk=\a"  1.43 CPU of 14 CPU  4.5 GiB of 7.7 GiB  14 CPU, 7.7 GiB

               ENVIRONMENT           CPU USED  MEMORY USED  CPU REQUESTED      MEMORY REQUESTED  PODS
               "prod\e]52;c;aGk=\a"  13m CPU   526 MiB      200m CPU of 2 CPU  512 MiB of 4 GiB  2 of 20
               review-7              0m CPU    0 MiB        no quota yet       no quota yet      no quota yet
              The quota limits what the pods of an environment request. A pod can use more than it requested, up to its limit.

               APPLICATION          ENVIRONMENT           PODS  CPU USED  MEMORY USED
               "app\e]52;c;aGk=\a"  "prod\e]52;c;aGk=\a"  1     6m CPU    263 MiB
              """, ""}
  end

  test "a refused read exits 3 with EHOS's sentence", %{provider: provider, opts: opts} do
    FakeProvider.stub_api(provider, "GET", "/api/v1/installation", fn _ ->
      {403,
       %{
         "error" => "forbidden",
         "message" => "Reading the installation needs one of ehos.application.register."
       }}
    end)

    assert ehosctl(["installation"], opts) ==
             {3, "",
              "ehosctl: Reading the installation needs one of ehos.application.register.\n"}
  end

  test "refuses a reading it cannot read, rather than print it in part",
       %{provider: provider, opts: opts} do
    for broken <- [
          Map.delete(@reading, "usage"),
          %{@reading | "quotas" => "maybe"},
          %{@reading | "ehos" => %{"commit" => "db57a37"}},
          put_in(@reading, ["ehos", "installed_at"], "yesterday"),
          put_in(@reading, ["ehos", "commit"], 7),
          put_in(@reading, ["installation", "console"], nil),
          %{@reading | "four_eyes" => %{"on" => "yes"}},
          %{@reading | "four_eyes" => %{"on" => true, "since" => 1}},
          %{
            @reading
            | "nodes" => [%{"name" => "n", "capacity" => %{"cpu_millicores" => "lots"}}]
          },
          %{@reading | "environments" => [%{"name" => "x", "applications" => "none"}]},
          put_in(@reading, ["environments", Access.at(0), "quota", "pods"], -1),
          put_in(@reading, ["environments", Access.at(0), "used", "memory_bytes"], 10 ** 400),
          put_in(
            @reading,
            ["environments", Access.at(0), "applications", Access.at(0), "pods"],
            1.5
          )
        ] do
      serve(provider, broken)

      assert ehosctl(["installation"], opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} answered with something ehosctl cannot read.\n"},
             inspect(broken)
    end
  end

  defp serve(provider, reading) do
    FakeProvider.stub_api(provider, "GET", "/api/v1/installation", fn _ -> {200, reading} end)
  end
end
