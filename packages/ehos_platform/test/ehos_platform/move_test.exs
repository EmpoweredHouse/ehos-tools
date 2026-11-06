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

  @addresses_jsonpath ~S'jsonpath={range .items[*]}{.spec.dnsNames[0]}={.spec.issuerRef.name}={.metadata.generation}={.status.conditions[?(@.type=="Ready")].status}={.status.conditions[?(@.type=="Ready")].observedGeneration}{"\n"}{end}'

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
                "EHOS's chart renders no ACME issuers and ehos-acme-issuers policy: it is " <>
                  "older than EHOS 0.26.0"}
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
                 "jsonpath={.spec.issuerRef.name}"
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

  describe "addresses/2" do
    test "returns at once when every address's certificate is issued for the new host" do
      record(fn ["get", "certificates.cert-manager.io", "-n", "ehos-addresses", "-o", _path] ->
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
                  @addresses_jsonpath
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
        {"ledger.production.ehos.192-0-2-7.sslip.io=ehos-local-ca=1=True=1\n" <>
           address("journal.production", "ehos-local-ca", "2=True=2") <>
           address("billing.production", "ehos-acme-addresses", "2=True=1") <>
           address("a.b", "ehos-acme-addresses", "4=True=4"), 0}
      end)

      expect(ClockMock, :sleep, 3, fn 10_000 -> :ok end)

      assert Move.addresses(@target, addresses_timeout: 30_000) ==
               {:ok,
                [
                  "billing.production.ehos.client.example",
                  "journal.production.ehos.client.example",
                  "ledger.production.ehos.192-0-2-7.sslip.io"
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

  # An address's Certificate as `addresses/2` reads it: its name under the new host, its issuer,
  # then its generation, whether it is ready and for which generation.
  defp address(name, issuer, state), do: "#{name}.ehos.client.example=#{issuer}=#{state}\n"

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
