defmodule Ehosctl.ResourcesListChangeTest do
  # eh-os D-192: `ehosctl resources mark-gone` and `remove-database` change one entry of the list
  # of databases outside the installation and install the EHOS that runs again.
  # Not async: capture_io(:stderr) captures stderr for every process.
  use Ehosctl.Case, async: false

  alias Ehosctl.FakeGitHub

  @moduletag :tmp_dir

  @env %{"GHCR_TOKEN" => "ghp_token", "EHOS_STATE_PASSPHRASE" => "a passphrase of 16+"}
  @host "ehos.acme.example.org"
  @image "ghcr.io/empoweredhouse/ehos@sha256:" <> String.duplicate("b", 64)
  @chart "oci://ghcr.io/empoweredhouse/charts/ehos@sha256:" <> String.duplicate("c", 64)
  @digest "sha256:" <> String.duplicate("b", 64)
  @running %{"version" => "0.30.0", "image" => @image, "chart" => @chart}

  # In place of `EhosPlatform.Install`: answers what runs as the test puts it, and says what it
  # was asked to render, install and delete.
  defmodule Platform do
    @moduledoc false

    def installed(opts) do
      send(self(), {:installed, opts})
      Process.get({__MODULE__, :installed})
    end

    def render_running(opts) do
      send(self(), {:render, opts})
      Process.get({__MODULE__, :rendered}, {:ok, "---\n"})
    end

    def server(opts) do
      send(self(), {:server, opts})

      case Process.get({__MODULE__, :server}) do
        nil ->
          dir = opts[:home] |> Path.expand() |> Path.join(opts[:name])
          File.write!(Path.join(dir, "install.json"), ~s({"host":"ehos.acme.example.org"}))
          File.write!(Path.join(dir, "ca.crt"), Process.get({__MODULE__, :ca}))

          {:ok,
           %EhosPlatform.Report{outcome: "EHOS is running at https://ehos.acme.example.org."}}

        refused ->
          refused
      end
    end

    def delete_external_secret(opts, name) do
      send(self(), {:delete_secret, opts, name})
      Process.get({__MODULE__, :deleted}, {:ok, :deleted})
    end
  end

  setup %{tmp_dir: dir} do
    github = FakeGitHub.start()
    FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [release()])

    %{cert: der} = :public_key.pkix_test_root_cert(~c"EHOS CA", [])
    Process.put({Platform, :ca}, :public_key.pem_encode([{:Certificate, der, :not_encrypted}]))
    stub_env(@env)

    opts = [
      install: Platform,
      runner: Ehosctl.CommandRunnerMock,
      home: Path.join(dir, "ehos"),
      config_dir: Path.join(dir, "config")
    ]

    File.mkdir_p!(Path.join(opts[:home], "acme"))
    File.write!(Path.join([opts[:home], "acme", "server.tfvars.json"]), "{}")
    File.write!(Path.join([opts[:home], "acme", "installation.json"]), ~s({"provider": "oci"}))
    File.write!(Path.join([opts[:home], "acme", "kubeconfig"]), "{}")

    runs([listed("audit"), listed("ledger")])
    %{opts: opts}
  end

  describe "resources mark-gone" do
    test "installs the EHOS that runs again with the entry marked gone, the others kept", %{
      opts: opts
    } do
      {code, stdout, _stderr} =
        ehosctl(~w(resources mark-gone ledger --installation acme --yes), opts)

      assert code == 0

      assert stdout =~
               "ehosctl marks the database ledger outside the installation gone for good on " <>
                 "acme, which runs EHOS 0.30.0:"

      assert stdout =~ "✓ acme marks the database ledger outside the installation gone for good."
      assert stdout =~ "ehosctl resources remove-database ledger --installation acme"

      listed = [listed("audit"), Map.put(listed("ledger"), "gone", true)]
      assert_received {:render, render}
      assert render[:external_databases] == listed
      assert_received {:server, server}
      assert server[:external_databases] == listed
      assert server[:external_under_development] == true
      assert server[:installed] == @running
      refute_received {:delete_secret, _opts, _name}
    end

    test "refuses a database marked gone already, and one the list does not name", %{
      opts: opts
    } do
      runs([listed("audit"), Map.put(listed("ledger"), "gone", true)])

      assert {2, "", stderr} =
               ehosctl(~w(resources mark-gone ledger --installation acme --yes), opts)

      assert stderr =~ "acme marks the database ledger gone already."

      assert {2, "", stderr} =
               ehosctl(~w(resources mark-gone billing --installation acme --yes), opts)

      assert stderr =~ "acme lists no database billing outside the installation."
      refute_received {:render, _opts}
      refute_received {:server, _opts}
    end

    test "asks before it writes, and writes nothing without a yes", %{opts: opts} do
      stub(Ehosctl.TerminalMock, :input_terminal?, fn -> true end)
      stub(Ehosctl.TerminalMock, :gets, fn _question -> "n\n" end)

      assert {0, stdout, _stderr} =
               ehosctl(~w(resources mark-gone ledger --installation acme), opts)

      assert stdout =~ "ehosctl changed nothing."
      refute_received {:server, _opts}
    end
  end

  describe "resources remove-database" do
    test "installs the EHOS that runs again without the entry, then deletes its Secret", %{
      opts: opts
    } do
      {code, stdout, _stderr} =
        ehosctl(~w(resources remove-database ledger --installation acme --yes), opts)

      assert code == 0
      assert stdout =~ "✓ acme no longer lists the database ledger outside the installation."
      assert stdout =~ "ehosctl deleted the Secret ehos-data/ehos-external-ledger"

      assert_received {:server, server}
      assert server[:external_databases] == [listed("audit")]
      assert_received {:delete_secret, _opts, "ledger"}
    end

    test "takes the last entry away with an empty list, and keeps a Secret it did not make", %{
      opts: opts
    } do
      runs([listed("ledger")])
      Process.put({Platform, :deleted}, {:ok, {:kept, "it does not have the label"}})

      {0, stdout, _stderr} =
        ehosctl(~w(resources remove-database ledger --installation acme --yes), opts)

      assert_received {:server, server}
      assert server[:external_databases] == []

      assert stdout =~
               "ehosctl kept the Secret ehos-data/ehos-external-ledger, which it did not make: " <>
                 "it does not have the label."
    end

    # A tunnel that closed after the install: the command fails, and says to run it again, which
    # then finds the database out of the list and deletes only the Secret.
    test "fails when the Secret cannot be deleted, and deletes it when run again", %{opts: opts} do
      Process.put({Platform, :deleted}, {:error, "kubectl could not reach the cluster"})

      assert {1, _stdout, stderr} =
               ehosctl(~w(resources remove-database ledger --installation acme --yes), opts)

      assert stderr =~
               "acme no longer lists the database ledger outside the installation. ehosctl " <>
                 "could not delete the Secret ehos-data/ehos-external-ledger of its managing role"

      assert stderr =~
               "run `ehosctl resources remove-database ledger --installation acme` again"

      runs([listed("audit")])
      Process.put({Platform, :deleted}, {:ok, :deleted})
      flush_messages()

      assert {0, stdout, _stderr} =
               ehosctl(~w(resources remove-database ledger --installation acme --yes), opts)

      assert stdout =~ "ehosctl deleted the Secret ehos-data/ehos-external-ledger"
      refute_received {:server, _opts}
      assert_received {:delete_secret, _opts, "ledger"}
    end

    test "refuses a database the list does not name and that has no Secret", %{opts: opts} do
      Process.put({Platform, :deleted}, {:ok, :absent})

      assert {2, "", stderr} =
               ehosctl(~w(resources remove-database billing --installation acme --yes), opts)

      assert stderr =~ "acme lists no database billing outside the installation."
      refute_received {:server, _opts}
    end

    # EHOS's check before the upgrade refuses while a resource binding names the database.
    test "deletes no Secret when the install is refused", %{opts: opts} do
      Process.put(
        {Platform, :server},
        {:error,
         EhosPlatform.Failure.exited(
           "helm",
           1,
           "Error: UPGRADE FAILED: pre-upgrade hooks failed\n"
         )}
      )

      assert {1, _stdout, stderr} =
               ehosctl(~w(resources remove-database ledger --installation acme --yes), opts)

      assert stderr =~ "pre-upgrade hooks failed"
      refute_received {:delete_secret, _opts, _name}
    end
  end

  # What runs on acme: EHOS 0.30.0 listing `external`.
  defp runs(external),
    do:
      Process.put(
        {Platform, :installed},
        {:ok,
         %{
           running: @running,
           digest: @digest,
           host: @host,
           sign_in: nil,
           four_eyes: nil,
           four_eyes_runs: nil,
           mail: nil,
           allowed_domains: nil,
           external_databases: external,
           external_under_development: true,
           warnings: [],
           revision: 3,
           last: nil
         }}
      )

  defp release do
    described = %{
      "schema" => "ehos.release/v1",
      "component" => "ehos",
      "version" => "0.30.0",
      "image" => @image,
      "chart" => @chart
    }

    {"v0.30.0", %{"assets" => %{"release.json" => described}, "body" => "What 0.30.0 changed."}}
  end

  defp listed(name),
    do: %{
      "name" => name,
      "version" => 17,
      "host" => "#{name}.db.example.com",
      "port" => 5432,
      "database" => name,
      "ca" => "-----BEGIN CERTIFICATE-----\n",
      "addressRanges" => ["10.30.0.0/24"],
      "managingRoleSecret" => "ehos-external-#{name}"
    }

  defp flush_messages do
    receive do
      _message -> flush_messages()
    after
      0 -> :ok
    end
  end
end
