defmodule Ehosctl.InstallationTest do
  # `ehosctl installation` (eh-os#349, ehos-tools#91): the reading the console's Installation page
  # shows, from `GET /api/installation`.
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

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    :ok
  end

  defp serve(provider, reading) do
    FakeProvider.stub_api(provider, "GET", "/api/installation", fn _ -> {200, reading} end)
  end

  test "prints the installation, its nodes, and each environment's use against its quota",
       %{provider: provider, opts: opts} do
    serve(provider, @reading)

    {0, stdout, ""} = ehosctl(["installation"], opts)
    assert stdout =~ "ehos on k3d, at https://ehos.localhost"
    refute stdout =~ "Size:"
    assert stdout =~ ~r/NODE\s+CPU USED\s+MEMORY USED\s+CAPACITY/

    assert stdout =~
             ~r/k3d-ehos-server-0\s+1.43 CPU of 14 CPU\s+4.5 GiB of 7.7 GiB\s+14 CPU, 7.7 GiB/

    assert stdout =~
             ~r/production\s+13m CPU\s+526 MiB\s+200m CPU of 2 CPU\s+512 MiB of 4 GiB\s+2 of 20/

    assert stdout =~ ~r/review-7\s+0m CPU\s+0 MiB\s+no quota yet/
    assert stdout =~ ~r/ledger\s+production\s+1\s+6m CPU\s+263 MiB/
    refute stdout =~ "could not be listed"
  end

  test "--json gives the reading as EHOS answered it, without what it does not know",
       %{provider: provider, opts: opts} do
    serve(provider, put_in(@reading, ["installation", "extra"], "dropped"))

    {0, json, ""} = ehosctl(["installation", "--json"], opts)
    assert JSON.decode!(json) == @reading
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

    {0, stdout, ""} = ehosctl(["installation"], opts)
    assert stdout =~ "Size: 4 OCPUs, 24 GB"
    assert stdout =~ "The cluster's nodes could not be listed."
    assert stdout =~ "The environments' quotas could not be listed."
    assert stdout =~ "A cluster without metrics-server has none."
    assert stdout =~ ~r/production\s+not known\s+not known\s+not known/
    refute stdout =~ "NODE"
  end

  test "a refused read exits 3 with EHOS's sentence", %{provider: provider, opts: opts} do
    FakeProvider.stub_api(provider, "GET", "/api/installation", fn _ ->
      {403,
       %{
         "error" => "forbidden",
         "message" => "Reading the installation needs one of ehos.application.register."
       }}
    end)

    {3, "", stderr} = ehosctl(["installation"], opts)
    assert stderr =~ "ehos.application.register"
  end

  test "refuses a reading it cannot read, rather than print it in part",
       %{provider: provider, opts: opts} do
    for broken <- [
          Map.delete(@reading, "usage"),
          %{@reading | "quotas" => "maybe"},
          put_in(@reading, ["installation", "console"], nil),
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
      {1, "", stderr} = ehosctl(["installation"], opts)
      assert stderr =~ "cannot read"
    end
  end

  test "shows a name a terminal would act on as text, not as it is",
       %{provider: provider, opts: opts} do
    serve(provider, put_in(@reading, ["installation", "name"], "ehos\e[2J"))

    {0, stdout, ""} = ehosctl(["installation"], opts)
    refute stdout =~ "\e[2J"
    assert stdout =~ ~s("ehos\\e[2J")
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
    decoded = JSON.decode!(json)

    assert decoded["installation"]["region"] == nil and
             is_map_key(decoded["installation"], "size")

    assert %{"used" => nil} = hd(decoded["nodes"])
    refute is_map_key(hd(decoded["environments"])["quota"], "cpu_limits_millicores")
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

    {0, stdout, ""} = ehosctl(["installation"], opts)

    assert stdout =~
             ~r/production\s+13m CPU\s+526 MiB\s+200m CPU of 2 CPU\s+\? of 4 GiB\s+no limit/

    assert stdout =~ ~r/k3d-ehos-server-0\s+not known\s+not known\s+14 CPU, 7.7 GiB/
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
      {0, stdout, ""} = ehosctl(["installation"], opts)
      assert stdout =~ said
    end
  end

  test "says when there are no nodes, environments or applications",
       %{provider: provider, opts: opts} do
    serve(provider, %{@reading | "nodes" => [], "environments" => []})

    {0, stdout, ""} = ehosctl(["installation"], opts)
    assert stdout =~ "No nodes."
    assert stdout =~ "No environments."
    assert stdout =~ "No application's pods are running, or their use is not known."
  end

  test "gives an unread reading under --json as EHOS said it", %{provider: provider, opts: opts} do
    unread = %{@reading | "nodes" => nil, "quotas" => "unavailable", "usage" => "unavailable"}
    serve(provider, unread)

    {0, json, ""} = ehosctl(["installation", "--json"], opts)

    assert %{"nodes" => nil, "quotas" => "unavailable", "usage" => "unavailable"} =
             JSON.decode!(json)
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

    {0, stdout, ""} = ehosctl(["installation"], opts)
    refute stdout =~ "\e"
    refute stdout =~ "\a"
  end
end
