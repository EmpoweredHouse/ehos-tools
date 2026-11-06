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

  @addresses_jsonpath ~S'jsonpath={range .items[*]}{.spec.dnsNames[0]}={.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'

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
                  "than EHOS 0.28.0"}
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
    test "removes the installation's CA, its key, its policy and the console's old Secret" do
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
                 "name"
               ],
               [
                 "delete",
                 "clusterissuer/ehos-local-ca",
                 "validatingadmissionpolicybinding/ehos-local-ca",
                 "validatingadmissionpolicy/ehos-local-ca",
                 "--ignore-not-found"
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
               [
                 "delete",
                 "secret/ehos-governance-tls",
                 "-n",
                 "ehos-system",
                 "--ignore-not-found"
               ]
             ]
    end

    test "keeps the CA while the console's Certificate still names it" do
      calls =
        record(fn _args ->
          {"W1106 a warning\ncertificate.cert-manager.io/ehos-governance-tls\n", 0}
        end)

      assert Move.own_authority_removed(@target) ==
               {:error,
                "The console's certificate is still the installation's CA's, so the CA was " <>
                  "kept: run the command again"}

      assert length(calls.()) == 1
    end
  end

  describe "addresses/2" do
    test "returns at once when every address's certificate is ready" do
      record(fn ["get", "certificates.cert-manager.io", "-n", "ehos-addresses", "-o", _path] ->
        {"ledger.production.ehos.client.example=True\n", 0}
      end)

      expect(ClockMock, :sleep, 0, fn _ms -> :ok end)

      assert Move.addresses(@target) == {:ok, []}
    end

    test "polls until each is ready" do
      {:ok, answers} =
        Agent.start_link(fn ->
          [
            "ledger.production.ehos.client.example=False\njournal.production.ehos.client.example=\n",
            "ledger.production.ehos.client.example=True\njournal.production.ehos.client.example=True\n"
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

    test "lists the addresses still without a certificate when the wait ends" do
      record(fn _args ->
        {"ledger.production.ehos.client.example=False\n" <>
           "a.b.ehos.client.example=True\n" <>
           "journal.production.ehos.client.example=\n", 0}
      end)

      expect(ClockMock, :sleep, 3, fn 10_000 -> :ok end)

      assert Move.addresses(@target, addresses_timeout: 30_000) ==
               {:ok,
                [
                  "journal.production.ehos.client.example",
                  "ledger.production.ehos.client.example"
                ]}
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
