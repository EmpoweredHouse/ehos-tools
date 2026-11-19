defmodule EhosPlatform.MoveTest do
  use ExUnit.Case, async: true

  import Hammox

  alias EhosPlatform.ClockMock
  alias EhosPlatform.CommandRunnerMock
  alias EhosPlatform.Install
  alias EhosPlatform.Move
  alias EhosPlatform.Source

  setup :verify_on_exit!

  @target %Install{
    context: "ehos-trial",
    host: "ehos.client.example",
    source: Source.checkout("/src/eh-os"),
    runner: CommandRunnerMock,
    clock: ClockMock
  }

  # The chart rendered for ehos.client.example, as much of it as a move reads.
  @rendered """
  kind: ClusterIssuer
  metadata:
    name: ehos-acme-console
  spec:
    acme:
      solvers:
        - selector:
            dnsNames: [ehos.client.example]
  ---
  kind: ClusterIssuer
  metadata:
    name: ehos-acme-addresses
  ---
  kind: ValidatingAdmissionPolicy
  metadata:
    name: ehos-acme-issuers
  ---
  kind: ValidatingAdmissionPolicyBinding
  metadata:
    name: ehos-acme-issuers
  ---
  kind: Certificate
  metadata:
    name: ehos-governance-public-tls
  """

  @addresses_jsonpath ~S'jsonpath={range .items[*]}{.metadata.name}={.spec.dnsNames[0]}={.spec.issuerRef.name}={.metadata.generation}={.status.conditions[?(@.type=="Ready")].status}={.status.conditions[?(@.type=="Ready")].observedGeneration}{"\n"}{end}'

  describe "run/2" do
    test "installs nothing when the chart renders no console Certificate" do
      record(fn _args -> {"", 0} end)

      assert Move.run(@target,
               render: fn ->
                 {:ok, "kind: ClusterIssuer\nmetadata:\n  name: ehos-acme-console\n"}
               end,
               chart: fn -> flunk("the chart was installed") end
             ) ==
               {:error,
                "EHOS's chart renders no Certificate ehos-governance-public-tls: it is older " <>
                  "than EHOS 0.26.0"}
    end
  end

  describe "issuers/2" do
    test "applies the issuers' policy, then both issuers for the target's host, marked as the release's" do
      {:ok, applied} = Agent.start_link(fn -> [] end)

      record(fn ["apply", "--server-side", "--field-manager=helm", "-f", path] ->
        Agent.update(applied, &(&1 ++ [Jason.decode!(File.read!(path))]))
        {"", 0}
      end)

      assert Move.issuers(@target, @rendered) == :ok

      [%{"items" => policy}, %{"items" => issuers}] = Agent.get(applied, & &1)

      assert Enum.map(policy ++ issuers, &{&1["kind"], &1["metadata"]["name"]}) == [
               {"ValidatingAdmissionPolicy", "ehos-acme-issuers"},
               {"ValidatingAdmissionPolicyBinding", "ehos-acme-issuers"},
               {"ClusterIssuer", "ehos-acme-console"},
               {"ClusterIssuer", "ehos-acme-addresses"}
             ]

      assert Enum.all?(
               policy ++ issuers,
               &(&1["metadata"]["annotations"]["meta.helm.sh/release-name"] == "ehos")
             )

      [console, _addresses] = issuers

      assert get_in(console, ["spec", "acme", "solvers", Access.at(0), "selector", "dnsNames"]) ==
               ["ehos.client.example"]
    end

    test "makes no issuer when the policy is not applied" do
      calls = record(fn _args -> {"error: the server could not apply it", 1} end)

      assert Move.issuers(@target, @rendered) ==
               {:error,
                "`kubectl` failed with exit status 1:\nerror: the server could not apply it"}

      assert length(calls.()) == 1
    end

    test "applies nothing from a chart that renders no issuers" do
      record(fn _args -> flunk("kubectl was run") end)

      assert Move.issuers(@target, "kind: ConfigMap\nmetadata:\n  name: x\n") ==
               {:error,
                "EHOS's chart does not render ValidatingAdmissionPolicy ehos-acme-issuers, " <>
                  "ValidatingAdmissionPolicyBinding ehos-acme-issuers, ClusterIssuer " <>
                  "ehos-acme-console, ClusterIssuer ehos-acme-addresses: it is older than EHOS " <>
                  "0.26.0"}
    end

    test "names the one document a chart does not render, and applies nothing" do
      record(fn _args -> flunk("kubectl was run") end)
      rendered = String.replace(@rendered, "name: ehos-acme-addresses", "name: other")

      assert Move.issuers(@target, rendered) ==
               {:error,
                "EHOS's chart does not render ClusterIssuer ehos-acme-addresses: it is older " <>
                  "than EHOS 0.26.0"}
    end
  end

  describe "refused/1" do
    test "admits an installation with no domain mapped, reading past kubectl's warnings" do
      record(fn
        ["get", "ehosdeployments.ehos.empowered.house" | _] ->
          {"W1106 10:00:00 warnings.go:70] a warning\nehos-env-production/ledger=\n", 0}

        ["get", "certificates.cert-manager.io" | _] ->
          {"W1106 10:00:00 warnings.go:70] a warning\nehos-tls-ledger\n", 0}
      end)

      assert Move.refused(@target) == :ok
    end

    test "admits 49 addresses and the console, the most Let's Encrypt issues in a week" do
      record(fn
        ["get", "ehosdeployments.ehos.empowered.house" | _] -> {"", 0}
        ["get", "certificates.cert-manager.io" | _] -> {names(49), 0}
      end)

      assert Move.refused(@target) == :ok
    end

    test "says kubectl's failure" do
      record(fn _args -> {"error: the server doesn't have a resource type", 1} end)

      assert Move.refused(@target) ==
               {:error,
                "`kubectl` failed with exit status 1:\nerror: the server doesn't have a resource type"}
    end
  end

  describe "own_authority_removed/1" do
    test "removes the CA's key and issuers first, the console's old Secret, then the CA's policy" do
      calls = record(fn _args -> {"", 0} end)

      assert Move.own_authority_removed(@target) == :ok

      assert calls.() == [
               [
                 "get",
                 "certificate",
                 "ehos-governance-tls",
                 "-n",
                 "ehos-system",
                 "--ignore-not-found",
                 "-o",
                 "jsonpath={.spec.issuerRef.name}",
                 "--request-timeout=10s"
               ],
               [
                 "delete",
                 "certificate/ehos-local-ca",
                 "secret/ehos-local-ca",
                 "issuer/ehos-local-selfsigned",
                 "-n",
                 "cert-manager",
                 "--ignore-not-found"
               ],
               ["delete", "clusterissuer/ehos-local-ca", "--ignore-not-found"],
               [
                 "delete",
                 "issuer/ehos-local-ca",
                 "issuer/ehos-local-selfsigned",
                 "certificate/ehos-local-ca",
                 "secret/ehos-local-ca",
                 "secret/ehos-governance-tls",
                 "-n",
                 "ehos-system",
                 "--ignore-not-found"
               ],
               [
                 "delete",
                 "validatingadmissionpolicybinding/ehos-local-ca",
                 "validatingadmissionpolicy/ehos-local-ca",
                 "--ignore-not-found"
               ]
             ]
    end

    test "keeps the CA's policy when a step before it fails" do
      calls =
        record(fn
          ["delete", "clusterissuer/ehos-local-ca" | _] -> {"error: the server is busy", 1}
          _args -> {"", 0}
        end)

      assert Move.own_authority_removed(@target) ==
               {:error, "`kubectl` failed with exit status 1:\nerror: the server is busy"}

      refute Enum.any?(
               calls.(),
               &match?(["delete", "validatingadmissionpolicybinding/" <> _ | _], &1)
             )
    end

    test "keeps the CA while the console's Certificate still names it" do
      calls = record(fn _args -> {"ehos-local-ca\nW1106 a warning after it\n", 0} end)

      assert Move.own_authority_removed(@target) ==
               {:error,
                "The console's certificate is still the installation's CA's, so the CA was " <>
                  "kept: run the command again"}

      assert length(calls.()) == 1
    end

    test "removes the CA when the console's Certificate of that name is an ACME issuer's" do
      calls =
        record(fn
          ["get", "certificate", "ehos-governance-tls" | _] -> {"ehos-acme-console", 0}
          _args -> {"", 0}
        end)

      assert Move.own_authority_removed(@target) == :ok
      assert length(calls.()) == 5
    end
  end

  describe "abandoned_removed/1" do
    @abandoned_get [
      "get",
      "certificate.cert-manager.io/ehos-governance-public-tls",
      "secret/ehos-governance-public-tls",
      "clusterissuer.cert-manager.io/ehos-acme-console",
      "clusterissuer.cert-manager.io/ehos-acme-addresses",
      "validatingadmissionpolicybinding.admissionregistration.k8s.io/ehos-acme-issuers",
      "validatingadmissionpolicy.admissionregistration.k8s.io/ehos-acme-issuers",
      "namespace/ehos-acme-dns",
      "-n",
      "ehos-system",
      "--ignore-not-found",
      "-o",
      "name",
      "--request-timeout=10s"
    ]

    test "removes the console's pending certificate and the issuers, then their policy, and says how to remove acme-dns" do
      calls =
        record(fn
          ["get" | _] ->
            {"certificate.cert-manager.io/ehos-governance-public-tls\n" <>
               "secret/ehos-governance-public-tls\n" <>
               "clusterissuer.cert-manager.io/ehos-acme-console\n" <>
               "clusterissuer.cert-manager.io/ehos-acme-addresses\n" <>
               "W1110 10:00:00 a warning\n" <>
               "validatingadmissionpolicy.admissionregistration.k8s.io/ehos-acme-issuers\n" <>
               "validatingadmissionpolicybinding.admissionregistration.k8s.io/ehos-acme-issuers\n" <>
               "namespace/ehos-acme-dns\n", 0}

          ["delete" | _] ->
            {"", 0}
        end)

      test = self()

      assert Move.abandoned_removed(%{@target | progress: &send(test, {:progress, &1})}) == :ok

      assert calls.() == [
               @abandoned_get,
               [
                 "delete",
                 "certificate/ehos-governance-public-tls",
                 "-n",
                 "ehos-system",
                 "--ignore-not-found"
               ],
               [
                 "delete",
                 "secret/ehos-governance-public-tls",
                 "-n",
                 "ehos-system",
                 "--ignore-not-found"
               ],
               ["delete", "clusterissuer/ehos-acme-console", "--ignore-not-found"],
               ["delete", "clusterissuer/ehos-acme-addresses", "--ignore-not-found"],
               [
                 "delete",
                 "validatingadmissionpolicybinding/ehos-acme-issuers",
                 "--ignore-not-found"
               ],
               ["delete", "validatingadmissionpolicy/ehos-acme-issuers", "--ignore-not-found"]
             ]

      assert progress() == [
               {:step,
                "Removing what an earlier run with public certificates left: the console's " <>
                  "certificate for the new host, its Secret " <>
                  "ehos-system/ehos-governance-public-tls, the ACME issuer ehos-acme-console, the " <>
                  "ACME issuer ehos-acme-addresses, the binding of their policy " <>
                  "ehos-acme-issuers, their policy ehos-acme-issuers"},
               {:warning,
                "acme-dns still runs in ehos-acme-dns, with the account that your " <>
                  "_acme-challenge record names.",
                "A later move uses it and the two Let's Encrypt account keys again. To remove " <>
                  "them, run `kubectl delete namespace ehos-acme-dns`. Then run `kubectl -n " <>
                  "cert-manager delete secret ehos-acme-dns ehos-acme-console " <>
                  "ehos-acme-addresses`. A later move then needs new _acme-challenge and CAA " <>
                  "records."}
             ]
    end

    # A first install with public certificates that stopped at the records made the issuers alone.
    test "removes only what it finds, and names it" do
      calls =
        record(fn
          ["get" | _] -> {"clusterissuer.cert-manager.io/ehos-acme-console\n", 0}
          ["delete" | _] -> {"", 0}
        end)

      test = self()

      assert Move.abandoned_removed(%{@target | progress: &send(test, {:progress, &1})}) == :ok

      assert calls.() == [
               @abandoned_get,
               ["delete", "clusterissuer/ehos-acme-console", "--ignore-not-found"]
             ]

      assert progress() == [
               {:step,
                "Removing what an earlier run with public certificates left: the ACME issuer " <>
                  "ehos-acme-console"}
             ]
    end

    test "removes nothing and says nothing when no move was started, or acme-dns alone is kept" do
      for found <- ["", "namespace/ehos-acme-dns\n"] do
        calls = record(fn ["get" | _] -> {found, 0} end)
        test = self()

        assert Move.abandoned_removed(%{@target | progress: &send(test, {:progress, &1})}) == :ok
        assert calls.() == [@abandoned_get]
        assert progress() == []
      end
    end

    test "keeps the issuers' policy when the issuers cannot be removed" do
      calls =
        record(fn
          ["get" | _] ->
            {"clusterissuer.cert-manager.io/ehos-acme-console\n" <>
               "validatingadmissionpolicy.admissionregistration.k8s.io/ehos-acme-issuers\n", 0}

          ["delete", "clusterissuer/" <> _ | _] ->
            {"error: the server is busy", 1}

          ["delete" | _] ->
            {"", 0}
        end)

      assert Move.abandoned_removed(%{@target | progress: fn _line -> :ok end}) ==
               {:error, "`kubectl` failed with exit status 1:\nerror: the server is busy"}

      refute Enum.any?(
               calls.(),
               &match?(["delete", "validatingadmissionpolicy" <> _ | _], &1)
             )
    end
  end

  describe "addresses/2" do
    test "returns at once when every address's certificate is issued for the new host" do
      record(fn [
                  "get",
                  "certificates.cert-manager.io",
                  "-n",
                  "ehos-addresses",
                  "-o",
                  _path,
                  "--request-timeout=10s"
                ] ->
        {address("ledger.production", "ehos-acme-addresses", "2=True=2"), 0}
      end)

      expect(ClockMock, :sleep, 0, fn _ms -> :ok end)

      assert Move.addresses(@target) == {:ok, []}
    end

    test "polls until each is issued for the new host" do
      {:ok, answers} =
        Agent.start_link(fn ->
          [
            address("ledger.production", "ehos-acme-addresses", "3=False=3") <>
              address("journal.production", "ehos-acme-addresses", "1==") <> "W1106 a warning\n",
            address("ledger.production", "ehos-acme-addresses", "3=True=3") <>
              address("journal.production", "ehos-acme-addresses", "1=True=1")
          ]
        end)

      record(fn [
                  "get",
                  "certificates.cert-manager.io",
                  "-n",
                  "ehos-addresses",
                  "-o",
                  @addresses_jsonpath,
                  "--request-timeout=10s"
                ] ->
        {Agent.get_and_update(answers, fn [answer | rest] -> {answer, rest} end), 0}
      end)

      expect(ClockMock, :sleep, 1, fn 10_000 -> :ok end)

      assert Move.addresses(@target) == {:ok, []}
    end

    # Straight after the chart, the operator has not yet given an address the new host: its
    # Certificate is still the old host's, ready, from the installation's CA.
    test "does not count a certificate still for the old host, from the CA, or ready for a spec before its last" do
      record(fn _args ->
        {"ehos-tls-ledger=ledger.production.ehos.192-0-2-7.sslip.io=ehos-local-ca=1=True=1\n" <>
           address("journal.production", "ehos-local-ca", "2=True=2") <>
           address("billing.production", "ehos-acme-addresses", "2=True=1") <>
           address("a.b", "ehos-acme-addresses", "4=True=4"), 0}
      end)

      expect(ClockMock, :sleep, 3, fn 10_000 -> :ok end)

      assert Move.addresses(@target,
               addresses_timeout: 30_000,
               moving_from: "ehos.192-0-2-7.sslip.io"
             ) ==
               {:ok,
                [
                  "billing.production.ehos.client.example",
                  "journal.production.ehos.client.example",
                  "ledger.production.ehos.client.example"
                ]}
    end

    test "names an address by its Certificate when its name is under neither host" do
      record(fn _args ->
        {"ehos-tls-ledger=ledger.production.ehos.192-0-2-7.sslip.io=ehos-local-ca=1=True=1\n", 0}
      end)

      expect(ClockMock, :sleep, 0, fn _ms -> :ok end)

      assert Move.addresses(@target, addresses_timeout: 5_000) ==
               {:ok, ["ehos-addresses/ehos-tls-ledger"]}
    end

    test "does not count a Certificate with no name, a wildcard, or a line it cannot read" do
      record(fn _args ->
        {"ehos-tls-blank==ehos-acme-addresses=1=True=1\n" <>
           "ehos-tls-wild=*.ehos.client.example=ehos-acme-addresses=1=True=1\n" <>
           "ehos-tls-odd=a=b\n" <>
           "W1110 10:00:00 a warning\n" <>
           address("ledger.production", "ehos-acme-addresses", "2=True=2"), 0}
      end)

      expect(ClockMock, :sleep, 0, fn _ms -> :ok end)

      assert Move.addresses(@target, addresses_timeout: 5_000) ==
               {:ok,
                [
                  "ehos-addresses/ehos-tls-blank",
                  "ehos-addresses/ehos-tls-odd",
                  "ehos-addresses/ehos-tls-wild"
                ]}
    end
  end

  describe "addresses/2 when kubectl fails" do
    test "reads again within the wait" do
      {:ok, answers} =
        Agent.start_link(fn ->
          [
            {"The connection to the server was refused", 1},
            {address("ledger.production", "ehos-acme-addresses", "2=True=2"), 0}
          ]
        end)

      record(fn _args ->
        Agent.get_and_update(answers, fn [answer | rest] -> {answer, rest} end)
      end)

      expect(ClockMock, :sleep, 1, fn 10_000 -> :ok end)

      assert Move.addresses(@target) == {:ok, []}
    end

    test "keeps the last read that succeeded when the last one fails" do
      {:ok, answers} =
        Agent.start_link(fn ->
          [
            {address("ledger.production", "ehos-acme-addresses", "2=False=2"), 0},
            {"The connection to the server was refused", 1}
          ]
        end)

      record(fn _args ->
        Agent.get_and_update(answers, fn [answer | rest] -> {answer, rest} end)
      end)

      expect(ClockMock, :sleep, 1, fn 10_000 -> :ok end)

      assert Move.addresses(@target, addresses_timeout: 10_000) ==
               {:ok, ["ledger.production.ehos.client.example"]}
    end

    test "reads once with no wait under 10 seconds" do
      record(fn _args ->
        {address("ledger.production", "ehos-acme-addresses", "2=False=2"), 0}
      end)

      expect(ClockMock, :sleep, 0, fn _ms -> :ok end)

      assert Move.addresses(@target, addresses_timeout: 5_000) ==
               {:ok, ["ledger.production.ehos.client.example"]}
    end

    test "says kubectl's failure when every read fails until the wait ends" do
      record(fn _args -> {"The connection to the server was refused", 1} end)
      expect(ClockMock, :sleep, 3, fn 10_000 -> :ok end)

      assert Move.addresses(@target, addresses_timeout: 30_000) ==
               {:error,
                "`kubectl` failed with exit status 1:\nThe connection to the server was refused"}
    end
  end

  # An address's Certificate as `addresses/2` reads it: the Certificate's name, its name under the
  # new host, its issuer, then its generation, whether it is ready and for which generation.
  defp address(name, issuer, state),
    do: "ehos-tls-#{name}=#{name}.ehos.client.example=#{issuer}=#{state}\n"

  defp progress do
    receive do
      {:progress, event} -> [event | progress()]
    after
      0 -> []
    end
  end

  defp names(count), do: Enum.map_join(1..count, "\n", &"ehos-tls-a#{&1}")

  # Each kubectl call's arguments after the context, answered by `answer`.
  defp record(answer) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    stub(CommandRunnerMock, :run, fn "kubectl", ["--context", "ehos-trial" | args] ->
      Agent.update(agent, &[args | &1])
      answer.(args)
    end)

    fn -> agent |> Agent.get(& &1) |> Enum.reverse() end
  end
end
