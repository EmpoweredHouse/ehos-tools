defmodule Ehosctl.ResourcesAddDatabaseTest do
  # Not async: capture_io(:stderr) captures stderr for every process.
  use Ehosctl.Case, async: false

  alias Ehosctl.CommandRunnerMock
  alias EhosPlatform.ExternalDatabases

  @moduletag :tmp_dir

  @env %{"GHCR_TOKEN" => "ghp_token", "EHOS_STATE_PASSPHRASE" => "a passphrase of 16+"}
  @password "s3cret-of-the-managing-role"
  @host "ehos.acme.example.org"
  @image "ghcr.io/empoweredhouse/ehos@sha256:" <> String.duplicate("b", 64)
  @chart "oci://ghcr.io/empoweredhouse/charts/ehos@sha256:" <> String.duplicate("c", 64)
  @digest "sha256:" <> String.duplicate("b", 64)
  @running %{"version" => "0.30.0", "image" => @image, "chart" => @chart}

  # In place of `EhosPlatform.Install`: answers what runs as the test puts it, says what it was
  # asked to render and install, and writes the Secret with the real one, whose runner is the
  # test's mock.
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

    defdelegate write_external_secret(opts, name, username, password), to: EhosPlatform.Install

    def server(opts) do
      send(self(), {:server, opts})
      dir = opts[:home] |> Path.expand() |> Path.join(opts[:name])
      File.write!(Path.join(dir, "install.json"), ~s({"host":"ehos.acme.example.org"}))
      File.write!(Path.join(dir, "ca.crt"), Process.get({__MODULE__, :ca}))
      {:ok, "EHOS is running at https://ehos.acme.example.org."}
    end
  end

  setup %{tmp_dir: dir} do
    %{cert: der} = :public_key.pkix_test_root_cert(~c"Database CA", [])
    ca = :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
    Process.put({Platform, :ca}, ca)
    stub_env(@env)

    opts = [
      install: Platform,
      runner: CommandRunnerMock,
      home: Path.join(dir, "ehos"),
      config_dir: Path.join(dir, "config")
    ]

    # The server's state as `ehosctl server up` and `tunnel` leave it.
    File.mkdir_p!(Path.join(opts[:home], "acme"))
    File.write!(Path.join([opts[:home], "acme", "server.tfvars.json"]), "{}")
    File.write!(Path.join([opts[:home], "acme", "installation.json"]), ~s({"provider": "oci"}))
    File.write!(Path.join([opts[:home], "acme", "kubeconfig"]), "{}")

    ca_file = Path.join(dir, "ca.pem")
    File.write!(ca_file, ca)
    password_file = Path.join(dir, "password.txt")
    File.write!(password_file, @password <> "\n")

    runs(%{})

    %{
      opts: opts,
      ca: ca,
      argv:
        ~w(resources add-database ledger --installation acme --host ledger.db.example.com
           --database ledger --version 17 --address-range 10.20.0.0/24
           --address-range 10.20.1.0/24 --username ehos_manager) ++
          ["--ca-file", ca_file, "--password-file", password_file],
      password_file: password_file
    }
  end

  describe "resources add-database" do
    test "renders the chart with the new list, writes the Secret, and installs the version that runs again",
         %{opts: opts, argv: argv, ca: ca} do
      runs(%{
        external_databases: [listed("audit")],
        external_under_development: true,
        sign_in: %{"absolute" => "30d"},
        four_eyes: false,
        allowed_domains: ["client.example"]
      })

      secret = mock_secret_created()

      {code, stdout, stderr} =
        ehosctl(argv ++ ["--administrator-role", "alice@example.com"], opts)

      assert {code, stdout} ==
               {0,
                """
                ehosctl adds the database ledger outside the installation to acme, which runs EHOS 0.30.0:
                  Server               ledger.db.example.com:5432
                  Database             ledger
                  PostgreSQL           17
                  Address ranges       10.20.0.0/24, 10.20.1.0/24
                  CA                   1 certificate
                  Managing role        In the Secret ehos-data/ehos-external-ledger
                  Administrator role   alice@example.com
                ehosctl writes the Secret, then installs EHOS 0.30.0 again with the database in its list.
                ✓ acme lists the database ledger outside the installation. ehosctl made the Secret of its managing role.
                Next:
                  ehosctl resources check ledger --installation acme
                EHOS is running at https://ehos.acme.example.org.
                Sign in with `ehosctl login --installation acme`. It trusts the CA of the installation.
                """}

      assert stderr ==
               "==> Writing the managing role of ledger (ehos-data/ehos-external-ledger)\n"

      entry = %{
        "name" => "ledger",
        "version" => 17,
        "host" => "ledger.db.example.com",
        "port" => 5432,
        "database" => "ledger",
        "ca" => ca,
        "addressRanges" => ["10.20.0.0/24", "10.20.1.0/24"],
        "managingRoleSecret" => "ehos-external-ledger",
        "administratorRole" => "alice@example.com"
      }

      assert_received {:render, render}
      assert render[:external_databases] == [listed("audit"), entry]
      assert render[:external_under_development] == true
      assert render[:token] == "ghp_token"

      assert_received {:server, server}
      assert server[:external_databases] == [listed("audit"), entry]
      assert server[:external_under_development] == true
      assert server[:installed] == @running
      assert server[:digest] == @digest
      assert server[:host] == @host
      assert server[:sign_in] == %{"absolute" => "30d"}
      assert server[:four_eyes] == false
      assert server[:allowed_domains] == ["client.example"]

      # The password reached the temporary file alone, which only this user could read and which
      # is gone.
      assert {written, mode, path, calls} = secret.()
      assert written == ExternalDatabases.secret("ledger", "ehos_manager", @password)
      assert Bitwise.band(mode, 0o777) == 0o600
      refute File.exists?(path)
      refute_holds(Enum.flat_map(calls, &elem(&1, 1)))
      refute_holds(inspect(render) <> inspect(server))
      refute_holds(stdout <> stderr)
    end

    test "reads the password from standard input, and never from a terminal", %{
      opts: opts,
      argv: argv,
      password_file: password_file
    } do
      argv = Enum.map(argv, &if(&1 == password_file, do: "-", else: &1))

      stub(Ehosctl.TerminalMock, :input_terminal?, fn -> true end)

      assert ehosctl(argv, opts) ==
               {2, "",
                "ehosctl: ehosctl does not read the password from a terminal, which can show or " <>
                  "keep it. ehosctl changed nothing. Give --password-file with a file, or " <>
                  "--password-file - with a pipe or a file, as in `ehosctl resources " <>
                  "add-database ledger … --password-file - < password.txt`.\n"}

      refute_received {:installed, _opts}

      stub(Ehosctl.TerminalMock, :input_terminal?, fn -> false end)
      stub(Ehosctl.TerminalMock, :read_input, fn _count -> @password <> "\r\n" end)
      secret = mock_secret_created()

      assert {0, stdout, stderr} = ehosctl(argv, opts)
      assert {written, _mode, _path, _calls} = secret.()
      assert written["data"]["password"] == Base.encode64(@password)
      refute_holds(stdout <> stderr)
    end

    test "replaces the Secret it made before for the same database", %{opts: opts, argv: argv} do
      test = self()
      held = ExternalDatabases.secret("ledger", "old", "old", "41")

      stub(CommandRunnerMock, :run, fn "kubectl", args ->
        case kubectl_step(args) do
          ["get", "secret" | _] ->
            {Jason.encode!(held), 0}

          ["replace", "-f", path] ->
            send(test, {:replaced, Jason.decode!(File.read!(path))})
            {"secret/ehos-external-ledger replaced\n", 0}
        end
      end)

      assert {0, stdout, _stderr} = ehosctl(argv, opts)
      assert stdout =~ "ehosctl replaced the Secret of its managing role."
      assert_received {:replaced, replaced}
      assert replaced == ExternalDatabases.secret("ledger", "ehos_manager", @password, "41")
    end

    test "refuses a Secret of that name that it did not make, and installs nothing", %{
      opts: opts,
      argv: argv
    } do
      ours = ExternalDatabases.secret("ledger", "old", "old", "41")

      for {held, why} <- [
            {put_in(ours, ["metadata", "labels"], %{}),
             "it does not have the label app.kubernetes.io/managed-by: ehosctl"},
            {put_in(ours, ["metadata", "annotations"], %{}),
             "its annotation ehos.empowered.house/external-database does not name the " <>
               "database ledger"},
            {put_in(ours, ["metadata", "ownerReferences"], [
               %{"kind" => "Cluster", "name" => "ledger"}
             ]), "it belongs to the Cluster ledger"}
          ] do
        expect(CommandRunnerMock, :run, fn "kubectl", args ->
          assert ["get", "secret" | _] = kubectl_step(args)
          {Jason.encode!(held), 0}
        end)

        assert {1, _preview, stderr} = ehosctl(argv, opts)

        assert stderr =~
                 "ehosctl: The Secret ehos-data/ehos-external-ledger is there, and the " <>
                   "installer did not make it for ledger: #{why}. Nothing was written."

        refute_received {:server, _opts}
      end
    end

    test "prints a failing kubectl without the password or its base64", %{opts: opts, argv: argv} do
      stub(CommandRunnerMock, :run, fn "kubectl", args ->
        case kubectl_step(args) do
          ["get", "secret" | _] ->
            {~s|Error from server (NotFound): secrets "ehos-external-ledger" not found\n|, 1}

          ["create", "-f", _path] ->
            {"error: #{@password} and #{Base.encode64(@password)} refused\n", 1}
        end
      end)

      assert {1, stdout, stderr} = ehosctl(argv, opts)
      assert stderr =~ "error: [the password] and [the password] refused"
      refute_holds(stdout <> stderr)
      refute_received {:server, _opts}
    end

    test "refuses a name that the running EHOS lists already", %{opts: opts, argv: argv} do
      runs(%{external_databases: [listed("ledger")], external_under_development: true})

      assert ehosctl(argv, opts) ==
               {2, "",
                "ehosctl: acme lists the database ledger already. This command only adds a " <>
                  "database. To change or remove one, change the values of the Helm release " <>
                  "with helm, or install again. ehosctl changed nothing.\n"}

      refute_received {:render, _opts}
    end

    test "refuses an EHOS before 0.30.0, or none", %{opts: opts, argv: argv} do
      runs(%{running: %{@running | "version" => "0.29.0"}})

      assert ehosctl(argv, opts) ==
               {2, "",
                "ehosctl: acme runs EHOS 0.29.0, which cannot use a database outside the " <>
                  "installation. Databases outside the installation start in 0.30.0. Run " <>
                  "`ehosctl upgrade --installation acme` first. ehosctl changed nothing.\n"}

      runs(%{running: :none, digest: nil})

      assert ehosctl(argv, opts) ==
               {2, "",
                "ehosctl: acme runs no EHOS, so it has no list of resources. Run `ehosctl " <>
                  "install --installation acme` first. ehosctl changed nothing.\n"}

      refute_received {:render, _opts}
    end

    test "refuses a field the chart would refuse, before it reads the cluster", %{
      opts: opts,
      argv: argv
    } do
      for {from, to, said} <- [
            {"ledger", "Ledger",
             "NAME must be a DNS label of at most 50 characters: lowercase letters, digits " <>
               "and -, starting with a letter, and Ledger is not."},
            {"17", "15",
             "--version must be the major version of PostgreSQL, 16 or later, such as 17, and " <>
               "15 is not."},
            {"ledger.db.example.com", "10.0.0.5",
             "--host must be a lowercase DNS name with a dot, such as db.example.com, not an " <>
               "address, and 10.0.0.5 is not."},
            {"10.20.1.0/24", "10.0.0.0/16",
             "Each --address-range must be /20 or narrower, and 10.0.0.0/16 is wider: list " <>
               "the subnets of the database."},
            {"ehos_manager", "two words",
             "--username must be the name of a role, of at most 63 characters of printable " <>
               "ASCII without spaces, and two words is not."}
          ] do
        argv = Enum.map(argv, &if(&1 == from, do: to, else: &1))

        assert ehosctl(argv, opts) ==
                 {2, "",
                  "ehosctl: #{String.trim_trailing(said, ".")}. ehosctl changed nothing.\n"}
      end

      refute_received {:installed, _opts}
    end

    test "says the chart's refusal, and writes nothing", %{opts: opts, argv: argv} do
      Process.put(
        {Platform, :rendered},
        {:error,
         "`helm` failed with exit status 1:\nError: dataResources.external: offered for development only\n"}
      )

      assert ehosctl(argv, opts) ==
               {1, "",
                "ehosctl: The chart of EHOS refused the database, or could not be rendered. " <>
                  "ehosctl changed nothing.\n`helm` failed with exit status 1:\nError: " <>
                  "dataResources.external: offered for development only\n"}

      refute_received {:server, _opts}
    end
  end

  # What runs on acme, `fields` over EHOS 0.30.0 with nothing else given.
  defp runs(fields),
    do:
      Process.put(
        {Platform, :installed},
        {:ok,
         Map.merge(
           %{
             running: @running,
             digest: @digest,
             host: @host,
             sign_in: nil,
             four_eyes: nil,
             four_eyes_runs: nil,
             mail: nil,
             allowed_domains: nil,
             external_databases: nil,
             external_under_development: nil,
             warnings: [],
             last: nil
           },
           fields
         )}
      )

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

  # kubectl finds no Secret of that name and makes it. Returns a function that gives what the
  # file kubectl was given held, its mode and path, read while it was there, and every call.
  defp mock_secret_created do
    {:ok, agent} = Agent.start_link(fn -> %{calls: []} end)

    stub(CommandRunnerMock, :run, fn "kubectl" = program, args ->
      Agent.update(agent, &%{&1 | calls: &1.calls ++ [{program, args}]})

      case kubectl_step(args) do
        ["get", "secret", "ehos-external-ledger", "-n", "ehos-data", "-o", "json"] ->
          {~s|Error from server (NotFound): secrets "ehos-external-ledger" not found\n|, 1}

        ["create", "-f", path] ->
          read = {Jason.decode!(File.read!(path)), File.stat!(path).mode, path}
          Agent.update(agent, &Map.put(&1, :file, read))
          {"secret/ehos-external-ledger created\n", 0}
      end
    end)

    fn ->
      %{file: {written, mode, path}, calls: calls} = Agent.get(agent, & &1)
      {written, mode, path, calls}
    end
  end

  defp kubectl_step(["--kubeconfig", _, "--context", "ehos-acme" | rest]), do: rest

  defp refute_holds(text) when is_list(text), do: Enum.each(text, &refute_holds/1)

  defp refute_holds(text) do
    refute text =~ @password
    refute text =~ Base.encode64(@password)
  end
end
