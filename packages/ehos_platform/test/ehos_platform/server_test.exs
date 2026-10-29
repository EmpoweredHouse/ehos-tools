defmodule EhosPlatform.ServerTest do
  use ExUnit.Case, async: true

  import Hammox

  alias EhosPlatform.ClockMock
  alias EhosPlatform.CommandRunnerMock
  alias EhosPlatform.EnvMock
  alias EhosPlatform.PublicAddressMock
  alias EhosPlatform.Server
  alias EhosPlatform.Shell
  alias EhosPlatform.Source

  doctest Server

  setup :verify_on_exit!

  # SSH control commands (`-O`) run bounded, without the operator's ssh config (#291); the tests
  # below match them as the commands they are, through `run`.
  setup do
    stub(CommandRunnerMock, :run_bounded, fn "ssh", ["-F", "none" | args], 5_000 ->
      CommandRunnerMock.run("ssh", args)
    end)

    # The environment holds nothing a test does not set, nothing waits, and this machine leaves
    # through one address.
    stub(EnvMock, :get, fn _name -> nil end)
    stub(ClockMock, :sleep, fn _ms -> :ok end)
    stub(PublicAddressMock, :ask, fn _service -> {:ok, "198.51.100.4"} end)

    :ok
  end

  @moduletag :tmp_dir

  @gcp_instance "google_compute_instance.server"
  @passphrase "correct horse battery staple"
  @tenancy "ocid1.tenancy.oc1..tenancy"
  @address "203.0.113.7"
  @account "111122223333"
  @project "0123456789abcdef0123456789abcdef"
  @outputs ~s({"public_ip": {"value": "#{@address}"}, "ssh_user": {"value": "ubuntu"}, "account_id": {"value": "#{@account}"}, "project_id": {"value": "#{@project}"}})

  # As k3s writes it: everything named `default`, the server on the node's loopback.
  @k3s_kubeconfig """
  apiVersion: v1
  clusters:
  - cluster:
      certificate-authority-data: Q0E=
      server: https://127.0.0.1:6443
    name: default
  contexts:
  - context:
      cluster: default
      user: default
    name: default
  current-context: default
  kind: Config
  users:
  - name: default
    user:
      client-certificate-data: Q0VSVA==
      client-key-data: S0VZ
  """

  setup %{tmp_dir: tmp_dir} do
    home = Path.join(tmp_dir, "ehos")
    key = Path.join(tmp_dir, "id_ed25519")
    File.write!(key <> ".pub", "ssh-ed25519 AAAAkey operator\n")
    config = Path.join(tmp_dir, "oci-config")

    File.write!(config, """
    [DEFAULT]
    user=ocid1.user.oc1..user
    fingerprint=aa:bb
    tenancy=#{@tenancy}
    region=eu-frankfurt-1
    key_file=~/.oci/oci_api_key.pem
    """)

    opts = [
      runner: CommandRunnerMock,
      source: Source.checkout("/src/eh-os"),
      home: home,
      ssh_key: key,
      provider: "oci",
      oci_config: config,
      passphrase: @passphrase,
      env: EnvMock,
      clock: ClockMock,
      public_address: PublicAddressMock
    ]

    %{opts: opts, dir: Path.join(home, "trial")}
  end

  describe "every command" do
    test "refuses an option T-20 replaced with a module, saying which module to give", %{
      opts: opts
    } do
      expect(CommandRunnerMock, :run, 0, fn _program, _args -> {"", 0} end)
      expect(CommandRunnerMock, :run_env, 0, fn _program, _args, _env -> {"", 0} end)

      for command <- [
            &Server.up/1,
            &Server.down/1,
            &Server.tunnel/1,
            &Server.close_tunnel/1,
            &Server.status/1,
            &Server.remote(&1, "true")
          ] do
        error =
          assert_raise ArgumentError, fn ->
            command.(Keyword.put(opts, :sleep, fn _ms -> :ok end))
          end

        assert Exception.message(error) ==
                 ":sleep is no longer taken; give :clock, a module that implements EhosPlatform.Clock"
      end

      error =
        assert_raise ArgumentError, fn ->
          Server.up(Keyword.put(opts, :detect_address, fn -> {:ok, "198.51.100.4"} end))
        end

      assert Exception.message(error) ==
               ":detect_address is no longer taken; give :public_address, a module that " <>
                 "implements EhosPlatform.PublicAddress"
    end

    # The passphrase is given, so only the provider's variables would read the environment.
    test "refuses the environment given as a map before running anything, and says none of it",
         %{opts: opts} do
      expect(CommandRunnerMock, :run_env, 0, fn _program, _args, _env -> {"", 0} end)
      opts = Keyword.merge(opts, provider: "aws", env: %{"AWS_SECRET_ACCESS_KEY" => "fixture"})

      assert_raise ArgumentError,
                   ":env must name a module that implements EhosPlatform.Env",
                   fn ->
                     Server.up(opts)
                   end
    end

    test "refuses without a passphrase of at least 16 characters, before running anything",
         %{opts: opts} do
      for passphrase <- [nil, "too short"],
          command <- [&Server.up/1, &Server.down/1, &Server.tunnel/1, &Server.status/1] do
        assert {:error, message} = command.(Keyword.put(opts, :passphrase, passphrase))
        assert message =~ "EHOS_STATE_PASSPHRASE"
      end
    end

    test "refuses to make a server on no provider, naming each, before running anything", %{
      opts: opts,
      dir: dir
    } do
      assert {:error, message} = Server.up(Keyword.delete(opts, :provider))
      assert message =~ "--provider aws, gcp, oci"
      assert Server.provider_named(Keyword.delete(opts, :provider)) == {:error, :invalid, message}
      refute File.exists?(dir)

      # Variables with no recorded provider, as an older `up` that stopped early left them.
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "server.tfvars.json"), ~s({"name": "trial"}))

      remote = &Server.remote(&1, "true")

      for command <- [&Server.down/1, &Server.tunnel/1, &Server.status/1, remote] do
        assert {:error, message} = command.(Keyword.delete(opts, :provider))
        assert message =~ "No installation trial"
        assert message =~ "up --provider PROVIDER`, PROVIDER one of aws, gcp, oci, ovh"
      end
    end

    # #345: an installation is made once `up` recorded where; variables alone, as an older `up`
    # that stopped before anything was made left them, are not one, whatever --provider says.
    test "takes variables without a recorded place for no installation, even with a provider", %{
      opts: opts,
      dir: dir
    } do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "server.tfvars.json"), "{}")
      refute Server.made?(opts)

      for command <- [&Server.down/1, &Server.tunnel/1, &Server.status/1] do
        assert {:error, message} = command.(opts)
        assert message =~ "No installation trial"
      end

      # A state too, and still no record: the record was lost. It is listed, so its commands say
      # to restore the record, and `up` refuses rather than plan from this command's options.
      File.write!(Path.join(dir, "terraform.tfstate"), "encrypted")
      assert Server.made?(opts)

      for command <- [&Server.down/1, &Server.status/1, &Server.up/1] do
        assert {:error, message} = command.(Keyword.put(opts, :provider, "aws"))
        assert message =~ "installation.json is missing" and message =~ "another place"
      end

      assert {:error, :failed, message} =
               Server.provider_named(Keyword.put(opts, :provider, "aws"))

      assert message =~ "installation.json is missing"
      File.rm!(Path.join(dir, "terraform.tfstate"))

      File.write!(Path.join(dir, "installation.json"), ~s({"provider": "oci"}))
      assert Server.made?(opts)

      # Oracle's, made before D-83: its variables and a state.
      File.rm!(Path.join(dir, "installation.json"))
      File.write!(Path.join(dir, "server.tfvars.json"), ~s({"tenancy_ocid": "t"}))
      File.write!(Path.join(dir, "terraform.tfstate"), "encrypted")
      assert Server.made?(opts)

      # A record that cannot be read is one, so the command that reads it says why, and `up`
      # fails on it rather than taking it for the command line's mistake.
      File.write!(Path.join(dir, "installation.json"), "{")
      assert Server.made?(opts)
      assert {:error, :failed, message} = Server.provider_named(opts)
      assert message =~ "cannot be read as an installation's place"
    end

    test "refuses a name OpenTofu's module would refuse", %{opts: opts} do
      for name <- ["Trial_1", "trial\n", "../trial"] do
        assert {:error, message} = Server.up(Keyword.put(opts, :name, name))
        assert message =~ "lowercase"

        assert Server.provider_named(Keyword.put(opts, :name, name)) ==
                 {:error, :invalid, message}
      end
    end
  end

  describe "ssh_cidr/1" do
    test "reads an address alone as /32 and a CIDR block as given" do
      assert Server.ssh_cidr("83.8.86.65") == {:ok, "83.8.86.65/32"}
      assert Server.ssh_cidr("83.8.86.65/32") == {:ok, "83.8.86.65/32"}
      assert Server.ssh_cidr("10.0.0.0/8") == {:ok, "10.0.0.0/8"}
      assert Server.ssh_cidr("128.0.0.0/1") == {:ok, "128.0.0.0/1"}
    end

    test "refuses host bits, naming the block and the address either could mean" do
      assert {:error, message} = Server.ssh_cidr("83.8.86.65/24")
      assert message =~ "--ssh-from 83.8.86.65/24 has host bits set"
      assert message =~ "83.8.86.0/24" and message =~ "83.8.86.65/32"
    end

    test "refuses IPv6, which no module admits SSH over" do
      for value <- ["2001:db8::1", "2001:db8::/32", "::ffff:192.0.2.1"] do
        assert {:error, message} = Server.ssh_cidr(value)
        assert message =~ "--ssh-from #{value} is IPv6"
      end
    end

    test "refuses the whole internet" do
      assert {:error, message} = Server.ssh_cidr("0.0.0.0/0")
      assert message =~ "--ssh-from 0.0.0.0/0 admits the whole internet"
    end

    test "refuses a prefix length written other than as a plain number, saying how to write it" do
      for {value, prefix} <- [{"192.0.2.0/024", "024"}, {"192.0.2.0/+24", "+24"}] do
        assert {:error, message} = Server.ssh_cidr(value)

        assert message =~
                 "--ssh-from #{value} writes its prefix length as #{prefix}; write it as 24"
      end
    end

    test "refuses what is not an address" do
      for value <-
            [
              "",
              "host.example",
              "192.0.2",
              "192.0.2.256",
              "192.0.2.0/",
              "192.0.2.0/33",
              "192.0.2.0/-1",
              "192.0.2.0/24/8",
              " 192.0.2.1",
              "192.0.2.1/32 "
            ] do
        assert {:error, message} = Server.ssh_cidr(value)
        assert message =~ "--ssh-from #{value} is not an IPv4 address or CIDR block"
      end
    end
  end

  describe "up/1" do
    test "writes the variables, applies the module with the state encrypted, and waits for k3s",
         %{opts: opts, dir: dir} do
      test_pid = self()

      expect(CommandRunnerMock, :run_env, 5, fn "tofu", args, env ->
        send(test_pid, {:tofu, args, Map.new(env)})
        tofu(args)
      end)

      # sshd is not up on the first try; the second sees cloud-init done.
      expect(CommandRunnerMock, :run, 2, fn "ssh", args ->
        send(test_pid, {:ssh, args})

        case Process.get(:ssh_tries, 0) do
          0 ->
            Process.put(:ssh_tries, 1)
            {"ssh: connect to host #{@address} port 22: Connection refused", 255}

          _ ->
            {"status: done\nboot_status_code: enabled-by-generator\n", 0}
        end
      end)

      assert {:ok, message} = Server.up(opts)
      assert message =~ @address

      assert_received {:tofu, ["-chdir=" <> module, "init" | init], env}
      assert String.ends_with?(module, "deploy/tofu/oci")
      assert "-lockfile=readonly" in init
      assert "-backend-config=path=#{Path.join(dir, "terraform.tfstate")}" in init
      assert env["TF_VAR_state_passphrase"] == @passphrase
      assert env["TF_DATA_DIR"] == Path.join(dir, "tofu")

      plan = Path.join(dir, "up.tfplan")
      assert_received {:tofu, [_chdir, "plan", "-input=false", "-out=" <> ^plan, var_file | _], _}
      # Planned from the variables beside the recorded ones, which they replace once applied.
      assert var_file == "-var-file=#{Path.join(dir, "server.tfvars.json.next")}"
      refute File.exists?(Path.join(dir, "server.tfvars.json.next"))
      assert_received {:tofu, [_chdir, "show", "-json", ^plan | _], _}
      assert_received {:tofu, [_chdir, "apply", "-input=false", "-auto-approve", ^plan | _], _}

      vars = dir |> Path.join("server.tfvars.json") |> File.read!() |> Jason.decode!()

      assert vars == %{
               "name" => "trial",
               "tenancy_ocid" => @tenancy,
               "region" => "eu-frankfurt-1",
               "oci_profile" => "DEFAULT",
               "availability_domain" => 0,
               "ssh_public_key" => "ssh-ed25519 AAAAkey operator",
               "ssh_from" => ["198.51.100.4/32"]
             }

      assert mode(dir) == 0o700
      assert mode(Path.join(dir, "server.tfvars.json")) == 0o600

      assert_received {:ssh, ssh_args}
      assert "StrictHostKeyChecking=accept-new" in ssh_args
      assert "HashKnownHosts=no" in ssh_args
      assert "UserKnownHostsFile=#{Path.join(dir, "known_hosts")}" in ssh_args
      assert "ubuntu@#{@address}" in ssh_args
    end

    # eh-os D-124: a server made with an ephemeral address gets a reserved one, a new address, once.
    test "says when the server's address changed, and how the console's host follows it", %{
      opts: opts,
      dir: dir
    } do
      for {before, said?} <- [{"192.0.2.1", true}, {@address, false}, {nil, false}] do
        # Each a server of its own: what a stopped run kept for the next is not carried over.
        File.rm(Path.join(dir, "previous_address"))

        prior =
          if before, do: %{"values" => %{"outputs" => %{"public_ip" => %{"value" => before}}}}

        stub(CommandRunnerMock, :run_env, fn "tofu", args, _env ->
          if "show" in args,
            do:
              {plan_json(["update"])
               |> Jason.decode!()
               |> Map.put("prior_state", prior)
               |> Jason.encode!(), 0},
            else: tofu(args)
        end)

        # Said before the server is reached, so a run that fails at SSH says it too.
        stub(CommandRunnerMock, :run, fn "ssh", _args -> {"Connection refused", 1} end)
        test_pid = self()
        progress = fn line -> send(test_pid, {:progress, line}) end
        assert {:error, _message} = Server.up(Keyword.put(opts, :progress, progress))
        lines = for {:progress, line} <- drain_messages(), do: line

        if said? do
          assert Enum.any?(lines, &(&1 =~ "address was 192.0.2.1 and is #{@address} now"))
          assert Enum.any?(lines, &(&1 =~ "--host #{EhosPlatform.Install.sslip_host(@address)}"))
        else
          refute Enum.any?(lines, &(&1 =~ "address was"))
        end
      end
    end

    # D-124: the same server at a new address has the same host key, which is required there.
    test "requires the old address's host key at the new one, and stops at another key", %{
      opts: opts,
      dir: dir
    } do
      known = Path.join(dir, "known_hosts")
      File.mkdir_p!(dir)
      # Its last line without a newline, as a file edited by hand may be.
      File.write!(known, "192.0.2.1 ssh-ed25519 AAAAold")
      prior = %{"values" => %{"outputs" => %{"public_ip" => %{"value" => "192.0.2.1"}}}}

      stub(CommandRunnerMock, :run_env, fn "tofu", args, _env ->
        if "show" in args,
          do:
            {plan_json(["update"])
             |> Jason.decode!()
             |> Map.put("prior_state", prior)
             |> Jason.encode!(), 0},
          else: tofu(args)
      end)

      stub(CommandRunnerMock, :run, fn "ssh", _args -> {"status: done\n", 0} end)
      assert {:ok, _message} = Server.up(opts)

      assert File.read!(known) ==
               "192.0.2.1 ssh-ed25519 AAAAold\n#{@address} ssh-ed25519 AAAAold\n"

      # Carried once: a second run adds nothing.
      assert {:ok, _message} = Server.up(opts)
      assert File.read!(known) =~ ~r/\A[^\n]*\n[^\n]*\n\z/

      stub(CommandRunnerMock, :run, fn "ssh", _args ->
        {"Host key verification failed.\r\n", 255}
      end)

      assert {:error, message} = Server.up(opts)
      assert message =~ "answered SSH with another host key"
    end

    # D-124: a run that stops after the apply leaves the next one's plan no change of address to
    # see; the old address is kept on disk until the server is reached at the new one.
    test "keeps the old address until the server is reached, across a run that stopped", %{
      opts: opts,
      dir: dir
    } do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "known_hosts"), "192.0.2.1 ssh-ed25519 AAAAold\n")
      kept = Path.join(dir, "previous_address")

      plan_with = fn before ->
        prior = %{"values" => %{"outputs" => %{"public_ip" => %{"value" => before}}}}

        stub(CommandRunnerMock, :run_env, fn "tofu", args, _env ->
          if "show" in args,
            do:
              {plan_json(["update"])
               |> Jason.decode!()
               |> Map.put("prior_state", prior)
               |> Jason.encode!(), 0},
            else: tofu(args)
        end)
      end

      plan_with.("192.0.2.1")
      stub(CommandRunnerMock, :run, fn "ssh", _args -> {"Connection refused", 1} end)
      assert {:error, _message} = Server.up(opts)
      assert File.read!(kept) == "192.0.2.1\n"

      # The state holds the new address now: the plan sees none changed.
      plan_with.(@address)
      stub(CommandRunnerMock, :run, fn "ssh", _args -> {"status: done\n", 0} end)
      test_pid = self()
      progress = fn line -> send(test_pid, {:progress, line}) end
      assert {:ok, _message} = Server.up(Keyword.put(opts, :progress, progress))
      lines = for {:progress, line} <- drain_messages(), do: line
      assert Enum.any?(lines, &(&1 =~ "address was 192.0.2.1 and is #{@address} now"))
      assert File.read!(Path.join(dir, "known_hosts")) =~ "#{@address} ssh-ed25519 AAAAold"
      refute File.exists?(kept)
    end

    test "never puts the passphrase on a command line", %{opts: opts} do
      test_pid = self()

      stub(CommandRunnerMock, :run_env, fn "tofu", args, _env ->
        send(test_pid, {:args, args})
        tofu(args)
      end)

      stub(CommandRunnerMock, :run, fn "ssh", args ->
        send(test_pid, {:args, args})
        {"status: done\n", 0}
      end)

      assert {:ok, _message} = Server.up(opts)

      for {:args, args} <- drain() do
        refute Enum.any?(args, &String.contains?(&1, @passphrase))
      end
    end

    test "refuses a plan that removes or replaces the server, and changes nothing", %{
      opts: opts,
      dir: dir
    } do
      test_pid = self()

      stub(CommandRunnerMock, :run_env, fn "tofu", args, _env ->
        send(test_pid, {:tofu, args})

        if "show" in args,
          do: {plan_json(["delete", "create"]), 0},
          else: tofu(args)
      end)

      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "server.tfvars.json"), ~s({"availability_domain": 2}))

      assert {:error, message} = Server.up(Keyword.put(opts, :availability_domain, 0))
      assert message =~ "oci_core_instance.server"
      assert message =~ "run `mix ehos.server up` again with --replace"
      assert File.read!(Path.join(dir, "server.tfvars.json")) == ~s({"availability_domain": 2})
      refute Enum.any?(drain(), &match?({:tofu, [_chdir, "apply" | _]}, &1))
      refute File.exists?(Path.join(dir, "up.tfplan"))
    end

    test "replaces the server when asked to, forgetting its host key and kubeconfig", %{
      opts: opts,
      dir: dir
    } do
      test_pid = self()
      File.mkdir_p!(dir)
      for file <- ~w(known_hosts kubeconfig), do: File.write!(Path.join(dir, file), "old")

      stub(CommandRunnerMock, :run_env, fn "tofu", args, _env ->
        send(test_pid, {:tofu, args})
        if "show" in args, do: {plan_json(["delete", "create"]), 0}, else: tofu(args)
      end)

      stub(CommandRunnerMock, :run, fn "ssh", _args -> {"status: done\n", 0} end)

      assert {:ok, _message} = Server.up(Keyword.put(opts, :replace, true))
      calls = drain()
      assert Enum.any?(calls, &match?({:tofu, [_chdir, "apply" | _]}, &1))

      assert [plan] = for({:tofu, [_chdir, "plan" | args]} <- calls, do: args)
      assert "-replace=oci_core_instance.server" in plan

      refute File.exists?(Path.join(dir, "kubeconfig"))
      refute File.exists?(Path.join(dir, "known_hosts"))
    end

    test "keeps the old server's host key and kubeconfig when the replacement fails", %{
      opts: opts,
      dir: dir
    } do
      File.mkdir_p!(dir)
      for file <- ~w(known_hosts kubeconfig), do: File.write!(Path.join(dir, file), "old")

      stub(CommandRunnerMock, :run_env, fn
        "tofu", [_chdir, "show" | _], _env -> {plan_json(["delete", "create"]), 0}
        "tofu", [_chdir, "apply" | _], _env -> {"Error: 401-NotAuthenticated\n", 1}
        "tofu", args, _env -> tofu(args)
      end)

      assert {:error, message} = Server.up(Keyword.put(opts, :replace, true))
      assert message =~ "401-NotAuthenticated"
      assert File.read!(Path.join(dir, "known_hosts")) == "old"
      assert File.read!(Path.join(dir, "kubeconfig")) == "old"
    end

    test "reads a plan past a warning that holds braces of its own", %{opts: opts} do
      stub(CommandRunnerMock, :run_env, fn "tofu", args, _env ->
        case tofu(args) do
          {"{" <> _ = json, 0} ->
            {"Warning: argument \"${var.x}\" is deprecated {see docs}\n" <>
               json <>
               "\nWarning: { trailing }\n", 0}

          other ->
            other
        end
      end)

      stub(CommandRunnerMock, :run, fn "ssh", _args -> {"status: done\n", 0} end)

      assert {:ok, _message} = Server.up(opts)
    end

    test "says when its home cannot be written instead of stopping with a trace", %{
      opts: opts,
      tmp_dir: tmp_dir
    } do
      home = Path.join(tmp_dir, "ehos-home")
      File.mkdir_p!(Path.join(home, "trial"))
      File.write!(Path.join(home, "plugin-cache"), "a file, not a directory")

      assert {:error, message} = Server.up(Keyword.put(opts, :home, home))
      assert message =~ "cannot be written"
    end

    test "keeps the availability domain it used before unless told another", %{
      opts: opts,
      dir: dir
    } do
      stub(CommandRunnerMock, :run_env, fn "tofu", args, _env -> tofu(args) end)
      stub(CommandRunnerMock, :run, fn "ssh", _args -> {"status: done\n", 0} end)
      vars = fn -> dir |> Path.join("server.tfvars.json") |> File.read!() |> Jason.decode!() end

      assert {:ok, _} = Server.up(Keyword.put(opts, :availability_domain, 2))
      assert vars.()["availability_domain"] == 2
      assert {:ok, _} = Server.up(opts)
      assert vars.()["availability_domain"] == 2
      assert {:ok, _} = Server.up(Keyword.put(opts, :availability_domain, 1))
      assert vars.()["availability_domain"] == 1
    end

    test "keeps the size it used before unless told another, and says a server is resized (D-84)",
         %{opts: opts, dir: dir} do
      test_pid = self()
      stub_oracle_server()
      stub(CommandRunnerMock, :run, fn "ssh", _args -> {"status: done\n", 0} end)
      vars = fn -> dir |> Path.join("server.tfvars.json") |> File.read!() |> Jason.decode!() end
      opts = Keyword.put(opts, :progress, &send(test_pid, {:progress, &1}))

      # Nothing asked is the module's default, which the variables leave to it.
      assert {:ok, _} = Server.up(opts)
      refute Map.has_key?(vars.(), "ocpus") or Map.has_key?(vars.(), "memory_gbs")

      _ = drain()

      assert {:ok, _} = Server.up(Keyword.merge(opts, ocpus: 1, memory_gb: 6))
      assert %{"ocpus" => 1, "memory_gbs" => 6} = vars.()

      assert [resized] = for({:progress, "Resizing ehos-trial" <> _ = l} <- drain(), do: l)
      assert resized =~ "(ocpus 2 → 1, memory_in_gbs 12 → 6)"

      assert {:ok, _} = Server.up(opts)
      assert %{"ocpus" => 1, "memory_gbs" => 6} = vars.()
      refute Enum.any?(drain(), &match?({:progress, "Resizing" <> _}, &1))

      assert {:ok, _} = Server.up(Keyword.put(opts, :memory_gb, 8))
      assert %{"ocpus" => 1, "memory_gbs" => 8} = vars.()
      assert Enum.any?(drain(), &match?({:progress, "Resizing" <> _}, &1))
    end

    test "says no resize when the size asked is the server's own, though the plan updates it (#285)",
         %{opts: opts} do
      test_pid = self()
      stub_oracle_server()
      stub(CommandRunnerMock, :run, fn "ssh", _args -> {"status: done\n", 0} end)
      opts = Keyword.put(opts, :progress, &send(test_pid, {:progress, &1}))

      assert {:ok, _} = Server.up(opts)
      _ = drain()

      # The module's default, asked for by name: nothing recorded, nothing resized.
      assert {:ok, _} = Server.up(Keyword.merge(opts, ocpus: 2, memory_gb: 12))
      refute Enum.any?(drain(), &match?({:progress, "Resizing" <> _}, &1))
    end

    test "keeps the variables when anything stops it before the apply, and says no resize (#285)",
         %{opts: opts, dir: dir} do
      test_pid = self()
      File.mkdir_p!(dir)
      path = Path.join(dir, "server.tfvars.json")
      recorded = ~s({"ocpus": 1, "memory_gbs": 6})
      File.write!(path, recorded)

      opts =
        Keyword.merge(opts, ocpus: 4, memory_gb: 24, progress: &send(test_pid, {:progress, &1}))

      stub_oracle_server()

      # No place recorded yet, so `up` writes installation.json before its first apply, and here
      # cannot, after a plan that would resize the server.
      File.mkdir_p!(Path.join(dir, "installation.json.partial"))
      assert {:error, message} = Server.up(opts)
      assert message =~ "installation.json cannot be written"
      assert File.read!(path) == recorded
      refute Enum.any?(drain(), &match?({:progress, "Resizing" <> _}, &1))
      File.rmdir!(Path.join(dir, "installation.json.partial"))

      # A step that raises, as an interrupt would stop it.
      stub(CommandRunnerMock, :run_env, fn
        "tofu", [_chdir, "plan" | _], _env -> raise "interrupted"
        "tofu", args, _env -> tofu(args)
      end)

      assert_raise RuntimeError, fn -> Server.up(opts) end
      assert File.read!(path) == recorded

      # Variables it could not read are left as they are, never removed.
      File.chmod!(path, 0o200)
      stub(CommandRunnerMock, :run_env, fn "tofu", _args, _env -> {"Error: no network\n", 1} end)
      assert {:error, _message} = Server.up(opts)
      File.chmod!(path, 0o600)
      assert File.read!(path) == recorded
    end

    test "keeps the size it had when the plan fails or would replace the server, and says no resize",
         %{opts: opts, dir: dir} do
      test_pid = self()
      File.mkdir_p!(dir)
      recorded = ~s({"ocpus": 1, "memory_gbs": 6})
      File.write!(Path.join(dir, "server.tfvars.json"), recorded)
      opts = Keyword.put(opts, :progress, &send(test_pid, {:progress, &1}))

      for {plan, show} <- [
            {{"Error: Invalid value for variable\n", 1}, nil},
            {{"", 0}, {plan_json(["delete", "create"]), 0}}
          ] do
        stub(CommandRunnerMock, :run_env, fn
          "tofu", [_chdir, "plan" | _], _env -> plan
          "tofu", [_chdir, "show" | _], _env -> show
          "tofu", args, _env -> tofu(args)
        end)

        assert {:error, _message} = Server.up(Keyword.merge(opts, ocpus: 4, memory_gb: 2))
        assert File.read!(Path.join(dir, "server.tfvars.json")) == recorded
        refute Enum.any?(drain(), &match?({:progress, "Resizing" <> _}, &1))
      end
    end

    test "refuses a recorded size no option would take", %{opts: opts, dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "server.tfvars.json"), ~s({"ocpus": {"a": 1}}))

      assert {:error, message} = Server.up(opts)
      assert message =~ "--ocpus is a whole number"
    end

    test "refuses another provider's size before running anything", %{opts: opts} do
      assert {:error, message} = Server.up(Keyword.put(opts, :instance_type, "t4g.large"))
      assert message =~ "does not size a server on oci"
    end

    test "keeps two installations in one home apart: files, state, OpenTofu's data and names",
         %{opts: opts, tmp_dir: tmp_dir} do
      test_pid = self()

      stub(CommandRunnerMock, :run_env, fn "tofu", args, env ->
        send(test_pid, {:tofu, args, Map.new(env)})
        tofu(args)
      end)

      stub(CommandRunnerMock, :run, fn "ssh", _args -> {"status: done\n", 0} end)

      home = Path.join(tmp_dir, "ehos")

      for {name, other} <- [{"trial", "acme"}, {"acme", "trial"}] do
        assert {:ok, message} = Server.up(Keyword.merge(opts, name: name, ocpus: 1, memory_gb: 6))
        assert message =~ "ehos-#{name}"

        dir = Path.join(home, name)
        calls = drain()
        assert calls != []

        for {:tofu, args, env} <- calls do
          assert env["TF_DATA_DIR"] == Path.join(dir, "tofu")
          refute Enum.any?(args, &String.contains?(&1, Path.join(home, other) <> "/"))
        end

        assert Enum.any?(calls, fn {:tofu, args, _env} ->
                 "-backend-config=path=#{Path.join(dir, "terraform.tfstate")}" in args
               end)

        vars = dir |> Path.join("server.tfvars.json") |> File.read!() |> Jason.decode!()
        assert %{"name" => ^name, "ocpus" => 1, "memory_gbs" => 6} = vars
      end
    end

    test "admits SSH from the blocks given instead of this machine's address", %{
      opts: opts,
      dir: dir
    } do
      stub(CommandRunnerMock, :run_env, fn "tofu", args, _env ->
        tofu(args)
      end)

      stub(CommandRunnerMock, :run, fn "ssh", _args -> {"status: done\n", 0} end)

      expect(PublicAddressMock, :ask, 0, fn _service -> {:ok, "198.51.100.4"} end)
      opts = Keyword.put(opts, :ssh_from, ["192.0.2.0/24"])

      assert {:ok, _message} = Server.up(opts)

      vars = dir |> Path.join("server.tfvars.json") |> File.read!() |> Jason.decode!()
      assert vars["ssh_from"] == ["192.0.2.0/24"]
    end

    test "admits a bare --ssh-from address as that address alone", %{opts: opts, dir: dir} do
      stub(CommandRunnerMock, :run_env, fn "tofu", args, _env -> tofu(args) end)
      stub(CommandRunnerMock, :run, fn "ssh", _args -> {"status: done\n", 0} end)

      assert {:ok, _message} =
               Server.up(Keyword.put(opts, :ssh_from, ["83.8.86.65", "192.0.2.0/24"]))

      vars = dir |> Path.join("server.tfvars.json") |> File.read!() |> Jason.decode!()
      assert vars["ssh_from"] == ["83.8.86.65/32", "192.0.2.0/24"]

      assert {:ok, _message} =
               Server.up(Keyword.put(opts, :ssh_from, ["83.8.86.65", "83.8.86.65/32"]))

      vars = dir |> Path.join("server.tfvars.json") |> File.read!() |> Jason.decode!()
      assert vars["ssh_from"] == ["83.8.86.65/32"]
    end

    # No runner is stubbed: a refused value runs nothing, on every provider.
    test "refuses an --ssh-from value the clouds would refuse before running anything, naming it",
         %{opts: opts, dir: dir} do
      for provider <- [
            [],
            [provider: "aws", aws_profile: "ehos"],
            [provider: "gcp", gcp_project: "p"]
          ],
          value <- ["192.0.2.1/24", "2001:db8::1", "0.0.0.0/0", "host.example", "192.0.2.0/33"] do
        opts =
          opts
          |> Keyword.merge(provider)
          |> Keyword.merge(ssh_from: ["198.51.100.0/24", value])

        assert {:error, message} = Server.up(opts)
        assert message =~ "--ssh-from #{value} "
        refute File.exists?(Path.join(dir, "server.tfvars.json"))
      end
    end

    test "says where to try again when Oracle has no Ampere capacity", %{opts: opts} do
      stub(CommandRunnerMock, :run_env, fn
        "tofu", [_chdir, "init" | _], _env ->
          {"", 0}

        "tofu", [_chdir, "apply" | _], _env ->
          {"Error: 500-InternalError, Out of host capacity.", 1}

        "tofu", args, _env ->
          tofu(args)
      end)

      assert {:error, message} = Server.up(opts)
      assert message =~ "Out of host capacity" and message =~ "--availability-domain"
    end

    test "shows the error OpenTofu ends with, not the plan it printed before", %{opts: opts} do
      stub(CommandRunnerMock, :run_env, fn
        "tofu", [_chdir, "init" | _], _env ->
          {"", 0}

        "tofu", [_chdir, "apply" | _], _env ->
          {"Plan: 1 to add\n  + metadata = { user_data = \"I2Nsb3Vk\" }\nError: 404-NotAuthorizedOrNotFound\n",
           1}

        "tofu", args, _env ->
          tofu(args)
      end)

      assert {:error, message} = Server.up(opts)
      assert message =~ "404-NotAuthorizedOrNotFound"
      refute message =~ "user_data"
    end

    test "says to admit this machine's address again when SSH never answers", %{opts: opts} do
      stub(CommandRunnerMock, :run_env, fn "tofu", args, _env ->
        tofu(args)
      end)

      stub(CommandRunnerMock, :run, fn "ssh", _args ->
        {"ssh: connect to host #{@address} port 22: Operation timed out", 255}
      end)

      assert {:error, message} = Server.up(opts)
      assert message =~ "never answered SSH" and message =~ "run `mix ehos.server up` again"
    end

    # ehos-tools#157: a network that leaves through more than one address.
    test "admits every address this machine was seen to leave from", %{opts: opts, dir: dir} do
      stub(CommandRunnerMock, :run_env, fn "tofu", args, _env -> tofu(args) end)
      stub(CommandRunnerMock, :run, fn "ssh", _args -> {"status: done\n", 0} end)

      stub(PublicAddressMock, :ask, fn
        "https://checkip.amazonaws.com" -> {:ok, "77.65.103.58"}
        _service -> {:ok, "83.8.86.65"}
      end)

      assert {:ok, _message} = Server.up(opts)

      vars = dir |> Path.join("server.tfvars.json") |> File.read!() |> Jason.decode!()
      assert vars["ssh_from"] == ["77.65.103.58/32", "83.8.86.65/32"]
    end

    test "refuses to make the server when no address was detected", %{opts: opts} do
      stub(PublicAddressMock, :ask, fn _service -> {:error, "it answered 503"} end)

      assert Server.up(opts) ==
               {:error,
                "This machine's public address is unknown (checkip.amazonaws.com: it answered " <>
                  "503; api.ipify.org: it answered 503; ipv4.icanhazip.com: it answered 503); " <>
                  "give it with --ssh-from"}
    end

    test "says which addresses are admitted while SSH does not answer, and when it never does",
         %{opts: opts} do
      stub(CommandRunnerMock, :run_env, fn "tofu", args, _env -> tofu(args) end)

      stub(CommandRunnerMock, :run, fn "ssh", _args ->
        {"ssh: connect to host #{@address} port 22: Operation timed out", 255}
      end)

      test = self()
      opts = Keyword.put(opts, :progress, &send(test, {:progress, &1}))

      assert {:error, message} = Server.up(opts)

      assert_received {:progress,
                       "Waiting for the server to answer SSH. " <>
                         "SSH is admitted from 198.51.100.4/32 only."}

      assert message =~ "SSH is admitted from 198.51.100.4/32 only."
      assert message =~ "more than one address"
      assert message =~ "give `--ssh-from` each of them"
    end

    test "keeps OpenTofu's state files readable by their owner alone", %{opts: opts, dir: dir} do
      stub(CommandRunnerMock, :run_env, fn "tofu", args, _env ->
        state = Path.join(dir, "terraform.tfstate")
        File.write!(state, "{}")
        File.chmod!(state, 0o644)
        tofu(args)
      end)

      stub(CommandRunnerMock, :run, fn "ssh", _args -> {"status: done\n", 0} end)

      assert {:ok, _message} = Server.up(opts)
      assert mode(Path.join(dir, "terraform.tfstate")) == 0o600
    end

    test "says where the log is when the first boot fails", %{opts: opts} do
      stub(CommandRunnerMock, :run_env, fn "tofu", args, _env ->
        tofu(args)
      end)

      stub(CommandRunnerMock, :run, fn "ssh", _args -> {"status: error\n", 1} end)

      assert {:error, message} = Server.up(opts)
      assert message =~ "/var/log/cloud-init-output.log"
    end

    test "accepts a first boot that finished with recoverable errors", %{opts: opts} do
      stub(CommandRunnerMock, :run_env, fn "tofu", args, _env -> tofu(args) end)

      stub(CommandRunnerMock, :run, fn "ssh", _args ->
        {"status: done\nrecoverable_errors:\n  WARNING: deprecated key\n", 2}
      end)

      assert {:ok, _message} = Server.up(opts)
    end

    test "reads OpenTofu's JSON past the warnings it prints beside it", %{opts: opts} do
      stub(CommandRunnerMock, :run_env, fn "tofu", args, _env ->
        case tofu(args) do
          {"{" <> _ = json, 0} -> {"Warning: a deprecated argument\n" <> json <> "\n", 0}
          other -> other
        end
      end)

      stub(CommandRunnerMock, :run, fn "ssh", _args -> {"status: done\n", 0} end)

      assert {:ok, message} = Server.up(opts)
      assert message =~ @address
    end

    test "says how to make the SSH key when it is missing", %{opts: opts, tmp_dir: tmp_dir} do
      assert {:error, message} =
               Server.up(Keyword.put(opts, :ssh_key, Path.join([tmp_dir, "Jane Doe", "none"])))

      key = String.replace(Path.join([tmp_dir, "Jane Doe", "none"]), "'", ~S('\''))
      assert message =~ "`ssh-keygen -t ed25519 -f '#{key}'`"
    end

    test "says how to write the public key when only it is missing", %{
      opts: opts,
      tmp_dir: tmp_dir
    } do
      path = Path.join([tmp_dir, "Jane Doe", "id_ed25519"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "a private key")

      assert {:error, message} = Server.up(Keyword.put(opts, :ssh_key, path))

      key = String.replace(path, "'", ~S('\''))
      assert message =~ "`ssh-keygen -y -f '#{key}' > '#{key}.pub'`"
      refute message =~ "-t ed25519"
    end

    # `ssh-keygen -y` that failed, its passphrase mistyped, leaves the file its redirect made.
    test "takes an empty public key for a missing one", %{opts: opts, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "operator_key")
      File.write!(path, "a private key")
      File.write!(path <> ".pub", " \n")

      assert {:error, message} = Server.up(Keyword.put(opts, :ssh_key, path))
      assert message =~ "#{path}.pub is empty. "
      assert message =~ "`ssh-keygen -y -f #{Shell.word(path)} > #{Shell.word(path <> ".pub")}`"
    end

    test "names why it cannot read a public key, and suggests nothing over it",
         %{opts: opts, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "operator_key")
      File.write!(path, "a private key")
      File.mkdir_p!(path <> ".pub")

      assert {:error, message} = Server.up(Keyword.put(opts, :ssh_key, path))
      assert message =~ "#{path}.pub cannot be read: illegal operation on a directory"
      refute message =~ "ssh-keygen"
    end
  end

  describe "up/1 on AWS and GCP (D-83)" do
    setup %{opts: opts} do
      stub(CommandRunnerMock, :run, fn "ssh", _args -> {"status: done\n", 0} end)
      # The developer's own AWS_PROFILE and GOOGLE_CLOUD_PROJECT never reach these tests, and each
      # names its provider where a command needs one: later ones read it from the installation.
      # OVHcloud's credentials are a clouds.yaml entry, never the developer's own (D-127).
      clouds = Path.join(Path.dirname(opts[:home]), "clouds.yaml")
      File.write!(clouds, "clouds:\n  ovh:\n    region_name: GRA11\n")

      opts =
        opts
        |> Keyword.delete(:provider)
        |> Keyword.merge(clouds_yaml: clouds)

      %{opts: opts}
    end

    test "runs the provider's module with its variables, and records the provider", %{
      opts: opts,
      dir: dir
    } do
      for {provider, extra, module, expected} <- [
            {"aws", [aws_profile: "ehos"], "deploy/tofu/aws",
             %{"region" => "eu-central-1", "aws_profile" => "ehos", "aws_account_id" => @account}},
            {"gcp", [gcp_project: "acme-ehos"], "deploy/tofu/gcp",
             %{"region" => "europe-west3", "project" => "acme-ehos"}},
            {"ovh", [], "deploy/tofu/ovh",
             %{"region" => "GRA11", "os_cloud" => "ovh", "project_id" => @project}}
          ] do
        test_pid = self()
        File.rm_rf!(dir)

        stub(CommandRunnerMock, :run_env, fn "tofu", args, _env ->
          send(test_pid, {:tofu, args})
          tofu(args)
        end)

        opts = opts |> Keyword.merge(extra) |> Keyword.merge(provider: provider)

        assert {:ok, _message} = Server.up(opts)

        assert [{:tofu, ["-chdir=" <> chdir | _]} | _] = drain()
        assert String.ends_with?(chdir, module)

        vars = dir |> Path.join("server.tfvars.json") |> File.read!() |> Jason.decode!()
        # The account or project is the module's to say, after the apply; the variables had none
        # yet.
        pinned = ["aws_account_id", "project_id"]
        assert Map.take(vars, Map.keys(expected) -- pinned) == Map.drop(expected, pinned)

        refute Map.has_key?(vars, "tenancy_ocid")
        assert vars["ssh_from"] == ["198.51.100.4/32"]

        assert dir |> Path.join("installation.json") |> File.read!() |> Jason.decode!() ==
                 Map.put(expected, "provider", provider)
      end
    end

    test "replaces the provider's own instance when asked to, on AWS without a lift", %{
      opts: opts
    } do
      test_pid = self()

      stub(CommandRunnerMock, :run_env, fn "tofu", args, _env ->
        send(test_pid, {:tofu, args})

        if "show" in args,
          do: {plan_json(["delete", "create"], "aws_instance.server"), 0},
          else: tofu(args)
      end)

      assert {:ok, _message} = Server.up(Keyword.merge(opts, provider: "aws", replace: true))
      assert [plan] = for({:tofu, [_chdir, "plan" | args]} <- drain(), do: args)
      assert "-replace=aws_instance.server" in plan
    end

    # ehos-tools#430: Compute Engine refuses deleting a protected instance, so the plan that
    # replaces it is made again once the protection is lifted, by an apply on the server alone.
    test "on GCP, lifts the deletion protection before it replaces the server", %{opts: opts} do
      test_pid = self()

      stub(CommandRunnerMock, :run_env, fn "tofu", args, env ->
        send(test_pid, {:tofu, args, env})

        cond do
          lift?(args) -> {lift_json(), 0}
          "show" in args -> {plan_json(["delete", "create"], @gcp_instance), 0}
          true -> tofu(args)
        end
      end)

      assert {:ok, _message} = Server.up(gcp(opts, replace: true))
      ran = for {:tofu, [_chdir, command | args], env} <- drain(), do: {command, args, env}

      assert [first, lift, again] = for({"plan", args, env} <- ran, do: {args, env})
      assert "-replace=#{@gcp_instance}" in elem(first, 0)
      assert "-target=#{@gcp_instance}" in elem(lift, 0)
      assert {"TF_VAR_deletion_protection", "false"} in elem(lift, 1)
      assert "-replace=#{@gcp_instance}" in elem(again, 0)
      assert {"TF_VAR_deletion_protection", nil} in elem(again, 1)

      assert [unprotect, replace] = for({"apply", args, _env} <- ran, do: Enum.at(args, -2))
      assert String.ends_with?(unprotect, "unprotect.tfplan")
      assert String.ends_with?(replace, "up.tfplan")
    end

    test "on GCP, replaces nothing when the lift would change more than the protection", %{
      opts: opts
    } do
      test_pid = self()

      stub(CommandRunnerMock, :run_env, fn "tofu", args, _env ->
        send(test_pid, {:tofu, args})

        cond do
          lift?(args) -> {lift_json(%{"machine_type" => "e2-standard-4"}), 0}
          "show" in args -> {plan_json(["delete", "create"], @gcp_instance), 0}
          true -> tofu(args)
        end
      end)

      assert {:error, message} = Server.up(gcp(opts, replace: true))
      assert message =~ "would also change #{@gcp_instance}"
      refute Enum.any?(drain(), &match?({:tofu, [_chdir, "apply" | _]}, &1))
    end

    test "on GCP, says the protection is lifted when up stops after the lift", %{opts: opts} do
      stub(CommandRunnerMock, :run_env, fn "tofu", args, _env ->
        cond do
          lift?(args) ->
            {lift_json(), 0}

          "show" in args ->
            {plan_json(["delete", "create"], @gcp_instance), 0}

          "apply" in args and not Enum.any?(args, &String.ends_with?(&1, "unprotect.tfplan")) ->
            {"Error: quota", 1}

          true ->
            tofu(args)
        end
      end)

      assert {:error, message} = Server.up(gcp(opts, replace: true))
      assert message =~ "Error: quota"
      assert message =~ "The deletion protection is lifted from ehos-gcpx"
      assert message =~ "`mix ehos.server up` turns it back on for a server still there"
    end

    test "lifts no protection for a plan that keeps the server, and takes the operator's " <>
           "TF_VAR_deletion_protection out of OpenTofu's environment",
         %{opts: opts} do
      test_pid = self()

      stub(CommandRunnerMock, :run_env, fn "tofu", args, env ->
        send(test_pid, {:tofu, args, env})
        tofu(args)
      end)

      assert {:ok, _message} = Server.up(gcp(opts, replace: true))
      ran = drain()
      refute Enum.any?(ran, fn {:tofu, args, _env} -> "-target=#{@gcp_instance}" in args end)

      assert Enum.all?(ran, fn {:tofu, _args, env} ->
               {"TF_VAR_deletion_protection", nil} in env
             end)
    end

    test "says a server is resized from its type before and after in the plan (D-84)", %{
      opts: opts
    } do
      test_pid = self()
      opts = Keyword.put(opts, :progress, &send(test_pid, {:progress, &1}))

      for {provider, instance, attribute} <- [
            {"aws", "aws_instance.server", "instance_type"},
            {"gcp", "google_compute_instance.server", "machine_type"},
            {"ovh", "openstack_compute_instance_v2.server", "flavor_name"}
          ] do
        stub(CommandRunnerMock, :run_env, fn "tofu", args, _env ->
          if "show" in args,
            do:
              {plan_json(["update"], instance, %{attribute => "small-1"}, %{
                 attribute => "large-2"
               }), 0},
            else: tofu(args)
        end)

        assert {:ok, _message} =
                 Server.up(
                   Keyword.merge(opts,
                     provider: provider,
                     gcp_project: "p",
                     name: provider <> "x",
                     instance_type: "large-2"
                   )
                 )

        assert [resized] = for({:progress, "Resizing" <> _ = line} <- drain(), do: line)
        assert resized =~ "(#{attribute} small-1 → large-2)"
      end
    end

    test "keeps the provider, project and region it used before", %{opts: opts, dir: dir} do
      stub(CommandRunnerMock, :run_env, fn "tofu", args, _env -> tofu(args) end)
      vars = fn -> dir |> Path.join("server.tfvars.json") |> File.read!() |> Jason.decode!() end

      first = Keyword.merge(opts, provider: "gcp", gcp_project: "acme", region: "europe-west4")
      assert {:ok, _} = Server.up(first)
      assert {:ok, _} = Server.up(opts)
      assert %{"project" => "acme", "region" => "europe-west4"} = vars.()
    end

    test "refuses to move an installation to another provider", %{opts: opts, dir: dir} do
      stub(CommandRunnerMock, :run_env, fn "tofu", args, _env -> tofu(args) end)
      assert {:ok, _} = Server.up(Keyword.merge(opts, provider: "aws"))

      assert {:error, message} = Server.up(Keyword.merge(opts, provider: "gcp", gcp_project: "p"))
      assert message =~ "ehos-trial is on aws, not gcp" and message =~ "--name"

      assert %{"provider" => "aws"} =
               Jason.decode!(File.read!(Path.join(dir, "installation.json")))
    end

    # D-127: a destroy and a targeted refresh read no data source, so the project is checked first.
    test "on OVHcloud, refuses down, status and the tunnel when the credentials scope another project",
         %{opts: opts} do
      test_pid = self()
      stub(CommandRunnerMock, :run_env, fn "tofu", args, _env -> tofu(args) end)
      assert {:ok, _} = Server.up(Keyword.put(opts, :provider, "ovh"))

      stub(CommandRunnerMock, :run_env, fn "tofu", args, _env ->
        send(test_pid, {:tofu, args})

        # The scope's plan, not `up`'s, which writes a plan file.
        if "plan" in args and not Enum.any?(args, &String.starts_with?(&1, "-out=")),
          do:
            {"Error: Resource postcondition failed\n\nThe credentials scope another project", 1},
          else: tofu(args)
      end)

      for command <- [&Server.down/1, &Server.status/1, &Server.tunnel/1] do
        assert {:error, message} = command.(opts)
        assert message =~ "plan before this command failed, so nothing was changed"
        assert message =~ "`mix ehos.server up --os-cloud ENTRY`"
        assert message =~ "Resource postcondition failed"
      end

      ran = for {:tofu, [_chdir | args]} <- drain(), do: args
      refute Enum.any?(ran, &(hd(&1) in ["destroy", "apply"]))
      # A refresh-only plan reports a failed condition as a warning, and succeeds.
      assert [_ | _] = plans = Enum.filter(ran, &(hd(&1) == "plan"))
      refute Enum.any?(plans, &("-refresh-only" in &1))
    end

    # D-126: only a server not made yet needs its cloud named.
    test "keeps an installation on Oracle without :provider once it is made", %{
      opts: opts,
      dir: dir
    } do
      stub(CommandRunnerMock, :run_env, fn "tofu", args, _env -> tofu(args) end)
      assert {:ok, _} = Server.up(Keyword.put(opts, :provider, "oci"))

      assert %{"provider" => "oci"} =
               Jason.decode!(File.read!(Path.join(dir, "installation.json")))

      assert Server.provider_named(opts) == :ok
      assert {:ok, _} = Server.up(opts)
      assert {:ok, _} = Server.status(opts)
    end

    test "reads an installation made before D-83 as Oracle's", %{opts: opts, dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "server.tfvars.json"), ~s({"tenancy_ocid": "t", "region": "r"}))
      File.write!(Path.join(dir, "terraform.tfstate"), "encrypted")
      assert Server.provider_named(opts) == :ok

      assert {:error, message} = Server.up(Keyword.merge(opts, provider: "aws"))
      assert message =~ "is on oci, not aws"
    end

    test "pins the account it made the server in, and refuses another account or region", %{
      opts: opts,
      dir: dir
    } do
      stub(CommandRunnerMock, :run_env, fn "tofu", args, _env -> tofu(args) end)
      vars = fn -> dir |> Path.join("server.tfvars.json") |> File.read!() |> Jason.decode!() end
      assert {:ok, _} = Server.up(Keyword.merge(opts, provider: "aws", aws_profile: "acme"))

      assert %{"aws_account_id" => @account, "region" => "eu-central-1"} =
               Jason.decode!(File.read!(Path.join(dir, "installation.json")))

      # The next run pins the provider to that account, whatever the profile names.
      assert {:ok, _} = Server.up(Keyword.put(opts, :aws_profile, "renamed"))
      assert %{"aws_account_id" => @account, "aws_profile" => "renamed"} = vars.()

      before = File.read!(Path.join(dir, "server.tfvars.json"))
      assert {:error, message} = Server.up(Keyword.put(opts, :region, "us-east-1"))
      assert message =~ "second server" and message =~ "--name"
      assert File.read!(Path.join(dir, "server.tfvars.json")) == before

      # status, tunnel and down hold a given region to the recorded one too.
      assert {:error, message} = Server.status(Keyword.put(opts, :region, "us-east-1"))
      assert message =~ "region eu-central-1 → us-east-1"

      # Named as the caller's operator names an installation.
      assert {:error, message} =
               Server.status(
                 Keyword.merge(opts, region: "us-east-1", name_option: "--installation")
               )

      assert message =~ "choose another --installation"

      # AWS_PROFILE set later in the shell keeps the recorded profile.
      stub(EnvMock, :get, fn _name -> "other" end)
      assert {:ok, _} = Server.up(opts)
      assert %{"aws_profile" => "acme"} = vars.()
    end

    test "pins the account even when the first apply fails partway", %{opts: opts, dir: dir} do
      stub(CommandRunnerMock, :run_env, fn
        "tofu", [_chdir, "apply", "-input=false" | _], _env -> {"Error: creating EC2 Instance", 1}
        "tofu", args, _env -> tofu(args)
      end)

      assert {:error, _message} = Server.up(Keyword.merge(opts, provider: "aws"))

      assert %{"aws_account_id" => @account} =
               Jason.decode!(File.read!(Path.join(dir, "installation.json")))
    end

    test "says so when a failed apply leaves the account unrecorded", %{opts: opts, dir: dir} do
      stub(CommandRunnerMock, :run_env, fn
        "tofu", [_chdir, "apply", "-input=false" | _], _env -> {"Error: creating VPC", 1}
        "tofu", [_chdir, "output" | _], _env -> {~s({"public_ip": {"value": null}}), 0}
        "tofu", args, _env -> tofu(args)
      end)

      assert {:error, message} = Server.up(Keyword.merge(opts, provider: "aws"))
      assert message =~ "creating VPC" and message =~ "account it was applied in is not recorded"

      refute Map.has_key?(
               Jason.decode!(File.read!(Path.join(dir, "installation.json"))),
               "aws_account_id"
             )
    end

    test "refuses a plan that replaces the provider's instance without --replace", %{opts: opts} do
      for {provider, instance} <- [
            {"aws", "aws_instance.server"},
            {"gcp", "google_compute_instance.server"}
          ] do
        stub(CommandRunnerMock, :run_env, fn "tofu", args, _env ->
          if "show" in args, do: {plan_json(["delete", "create"], instance), 0}, else: tofu(args)
        end)

        assert {:error, message} =
                 Server.up(
                   Keyword.merge(opts,
                     provider: provider,
                     gcp_project: "p",
                     name: provider <> "x"
                   )
                 )

        assert message =~ instance and message =~ "--replace"
      end
    end

    test "binds the name to nothing when a first up fails before anything is made", %{
      opts: opts,
      dir: dir
    } do
      stub(CommandRunnerMock, :run_env, fn
        "tofu", [_chdir, "plan" | _], _env -> {"Error: no valid credential sources", 1}
        "tofu", args, _env -> tofu(args)
      end)

      assert {:error, _message} = Server.up(opts)

      assert {:error, _message} =
               Server.up(Keyword.merge(opts, provider: "aws", aws_profile: "x"))

      refute File.exists?(Path.join(dir, "installation.json"))

      stub(CommandRunnerMock, :run_env, fn "tofu", args, _env -> tofu(args) end)
      assert {:ok, _} = Server.up(Keyword.merge(opts, provider: "gcp", gcp_project: "p"))
    end

    test "refuses an installation.json it cannot read rather than guessing Oracle", %{
      opts: opts,
      dir: dir
    } do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "installation.json"), ~s({"provider": "aw))

      assert {:error, message} = Server.status(opts)
      assert message =~ "installation.json" and message =~ "restore"
    end

    test "on AWS, takes exported static keys out of OpenTofu's environment, and runs down and the tunnel's refresh on the provider's module",
         %{opts: opts, dir: dir} do
      test_pid = self()

      stub(CommandRunnerMock, :run_env, fn "tofu", args, env ->
        send(test_pid, {:tofu, args, env})
        tofu(args)
      end)

      assert {:ok, _} = Server.up(Keyword.merge(opts, provider: "aws"))
      assert [{:tofu, _args, env} | _] = drain()
      assert {"AWS_ACCESS_KEY_ID", nil} in env
      assert {"TF_CLI_ARGS_plan", nil} in env

      stub(CommandRunnerMock, :run, fn "ssh", _args -> {"status: done\n", 0} end)
      assert {:ok, _} = Server.status(opts)
      refresh = for {:tofu, [_chdir, "apply", "-refresh-only" | args], _env} <- drain(), do: args
      assert ["-target=aws_instance.server" | _] = hd(refresh)

      File.write!(Path.join(dir, "tunnel.sock"), "")
      stub(CommandRunnerMock, :run, fn "ssh", _args -> {"", 0} end)
      assert {:ok, _} = Server.down(opts)
      assert [{:tofu, ["-chdir=" <> chdir | _], _env} | _] = drain()
      assert String.ends_with?(chdir, "deploy/tofu/aws")
    end

    test "says which providers there are, and that GCP needs a project", %{opts: opts} do
      assert {:error, message} = Server.up(Keyword.put(opts, :provider, "azure"))
      assert message =~ "aws, gcp, oci"

      assert {:error, message} =
               Server.up(Keyword.put(opts, :provider, "gcp"))

      assert message =~ "--gcp-project"
    end

    test "says to try another zone when the provider has no capacity", %{opts: opts} do
      stub(CommandRunnerMock, :run_env, fn
        "tofu", [_chdir, "apply" | _], _env ->
          {"Error: creating EC2 Instance: InsufficientInstanceCapacity", 1}

        "tofu", args, _env ->
          tofu(args)
      end)

      assert {:error, message} = Server.up(Keyword.put(opts, :provider, "aws"))
      assert message =~ "another --availability-domain" and message =~ "zones"
    end

    test "says where to compare the host key on the provider's console", %{opts: opts, dir: dir} do
      stub(CommandRunnerMock, :run_env, fn "tofu", args, _env ->
        if "apply" in args and "-refresh-only" not in args do
          File.write!(
            Path.join(dir, "known_hosts"),
            "#{@address} ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHJW8mIz6TFSkLmac1HAw5DFrXN80G7PEP11G/LYZ4qF\n"
          )
        end

        tofu(args)
      end)

      assert {:ok, message} = Server.up(Keyword.merge(opts, provider: "gcp", gcp_project: "p"))
      assert message =~ "serial port output"
    end
  end

  describe "tunnel/1" do
    setup %{opts: opts, dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "server.tfvars.json"), "{}")
      File.write!(Path.join(dir, "installation.json"), ~s({"provider": "oci"}))
      %{opts: opts}
    end

    test "opens the tunnel in the background and writes a kubeconfig only its owner reads",
         %{opts: opts, dir: dir} do
      test_pid = self()
      stub_tofu()

      stub(CommandRunnerMock, :run, fn
        "ssh", ["-S", _socket, "-O", "check" | _] ->
          {"Control socket connect: No such file or directory", 255}

        "sh", ["-c", script, log | args] ->
          send(test_pid, {:tunnel, script, log, args})
          {"", 0}

        "ssh", args ->
          true = "sudo cat /etc/rancher/k3s/k3s.yaml 2>/dev/null" in args
          {@k3s_kubeconfig, 0}
      end)

      assert {:ok, message} = Server.tunnel(opts)
      assert message =~ "127.0.0.1:16443" and message =~ "--context ehos-trial"
      # A path with nothing a shell reads in it is left unquoted.
      assert message =~
               "`kubectl --kubeconfig #{Path.join(dir, "kubeconfig")} --context ehos-trial get nodes`"

      refute message =~ "S0VZ"

      assert_received {:tunnel, ~S(exec ssh "$@" </dev/null >"$0" 2>&1), log, args}
      assert log == Path.join(dir, "tunnel.log")
      assert ["-f", "-N", "-M", "-S", socket | _] = Enum.drop_while(args, &(&1 != "-f"))
      assert socket == Path.join(dir, "tunnel.sock")
      assert "127.0.0.1:16443:127.0.0.1:6443" in args

      kubeconfig = Path.join(dir, "kubeconfig")
      assert mode(kubeconfig) == 0o600
      config = kubeconfig |> File.read!() |> Jason.decode!()
      assert config["current-context"] == "ehos-trial"

      assert [%{"name" => "ehos-trial", "cluster" => cluster}] = config["clusters"]
      assert cluster["server"] == "https://127.0.0.1:16443"
      assert cluster["certificate-authority-data"] == "Q0E="

      assert [%{"name" => "ehos-trial", "user" => %{"client-key-data" => "S0VZ"}}] =
               config["users"]

      assert config["contexts"] == [
               %{
                 "name" => "ehos-trial",
                 "context" => %{"cluster" => "ehos-trial", "user" => "ehos-trial"}
               }
             ]
    end

    test "refreshes the state from the provider before it reads the server's address",
         %{opts: opts, dir: dir} do
      test_pid = self()
      record_tunnel(dir, 16_443)

      stub(CommandRunnerMock, :run_env, fn "tofu", [_chdir | args], _env ->
        send(test_pid, {:tofu, args})
        tofu(args)
      end)

      stub(CommandRunnerMock, :run, fn
        "ssh", ["-S" | _] -> {"Master running", 0}
        "ssh", _args -> {@k3s_kubeconfig, 0}
      end)

      assert {:ok, _message} = Server.tunnel(opts)

      commands = for {:tofu, [command | rest]} <- drain(), do: {command, "-refresh-only" in rest}
      assert commands == [{"init", false}, {"apply", true}, {"output", false}]
    end

    test "quotes the kubeconfig in what it suggests when the home holds a space",
         %{opts: opts, tmp_dir: tmp_dir} do
      home = Path.join(tmp_dir, "Jane Doe")
      dir = Path.join(home, "trial")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "server.tfvars.json"), "{}")
      File.write!(Path.join(dir, "installation.json"), ~s({"provider": "oci"}))
      record_tunnel(dir, 17_443)
      stub_tofu()

      stub(CommandRunnerMock, :run, fn
        "ssh", ["-S", _socket, "-O", "check" | _] -> {"Master running (pid=42)", 0}
        "ssh", _args -> {@k3s_kubeconfig, 0}
      end)

      assert {:ok, message} = Server.tunnel(Keyword.merge(opts, home: home, port: 17_443))

      assert message =~
               "`kubectl --kubeconfig '#{dir}/kubeconfig' --context ehos-trial get nodes`"
    end

    test "keeps a tunnel that is already open", %{opts: opts, dir: dir} do
      stub_tofu()

      stub(CommandRunnerMock, :run, fn
        "ssh", ["-S", _socket, "-O", "check" | _] -> {"Master running (pid=42)", 0}
        "ssh", _args -> {@k3s_kubeconfig, 0}
        "sh", _args -> flunk("opened a second tunnel")
      end)

      record_tunnel(dir, 17_443)
      assert {:ok, _message} = Server.tunnel(Keyword.put(opts, :port, 17_443))
    end

    # #291: a master that does not answer may still hold the port; its socket is left for the
    # operator to stop it, rather than cleared beside a forward nothing could then close.
    # Under a home with a `'` and a `+` in it: the `pkill` it suggests quotes the one for the
    # shell, and escapes the other for the regular expression `pkill -f` reads.
    test "refuses, naming the master, when its own tunnel does not answer in time",
         %{opts: opts, tmp_dir: tmp_dir} do
      home = Path.join(tmp_dir, "Jane O'Brien+work")
      dir = Path.join(home, "trial")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "server.tfvars.json"), "{}")
      File.write!(Path.join(dir, "installation.json"), ~s({"provider": "oci"}))
      opts = Keyword.put(opts, :home, home)
      stub_tofu()
      socket = Path.join(dir, "tunnel.sock")
      File.write!(socket, "")
      record_tunnel(dir, 16_443)

      stub(CommandRunnerMock, :run_bounded, fn "ssh", ["-F", "none", "-S", ^socket | _], 5_000 ->
        {:error, :timeout}
      end)

      stub(CommandRunnerMock, :run, fn
        "sh", _args -> flunk("opened a second tunnel beside a master that may hold the port")
        "ssh", _args -> {@k3s_kubeconfig, 0}
      end)

      assert {:error, message} = Server.tunnel(opts)
      assert message =~ "does not answer on #{socket}"
      assert File.exists?(socket)

      assert {:error, message} = Server.close_tunnel(opts)
      assert message =~ "`pkill -f #{socket |> Shell.pattern() |> Shell.word()}`"
      assert message =~ ~S(/Jane O'\''Brien\+work/trial/tunnel\.sock'`)

      # Its record stays, so no other tunnel takes the port it may still hold.
      assert File.exists?(Path.join(dir, "tunnel.json"))
    end

    test "clears a control socket left by a master that is gone before it opens a new one",
         %{opts: opts, dir: dir} do
      stub_tofu()
      socket = Path.join(dir, "tunnel.sock")
      File.write!(socket, "")

      stub(CommandRunnerMock, :run, fn
        "ssh", ["-S", _socket, "-O", "check" | _] ->
          {"Control socket connect: Connection refused", 255}

        "sh", _args ->
          refute File.exists?(socket)
          {"", 0}

        "ssh", _args ->
          {@k3s_kubeconfig, 0}
      end)

      assert {:ok, _message} = Server.tunnel(opts)
    end

    # #291: a master that does not answer within the bound is not waited on for ever; its port
    # counts as held, the conservative answer.
    test "counts another installation's tunnel that does not answer in time as holding its port",
         %{opts: opts, tmp_dir: tmp_dir} do
      test_pid = self()
      stub_tofu()
      home = Path.join(tmp_dir, "ehos")
      wedged = Path.join([home, "acme", "tunnel.sock"])

      stub(CommandRunnerMock, :run_bounded, fn
        "ssh", ["-F", "none", "-S", ^wedged, "-O", "check" | _], 5_000 ->
          {:error, :timeout}

        "ssh", ["-F", "none" | args], 5_000 ->
          CommandRunnerMock.run("ssh", args)
      end)

      stub(CommandRunnerMock, :run, fn
        "ssh", ["-S", _socket, "-O", "check" | _] ->
          {"Control socket connect: No such file or directory", 255}

        "sh", ["-c", _script, _log | args] ->
          send(test_pid, {:forward, Enum.at(args, -2)})
          {"", 0}

        "ssh", _args ->
          {@k3s_kubeconfig, 0}
      end)

      File.mkdir_p!(Path.join(home, "acme"))
      record_tunnel(Path.join(home, "acme"), 16_443)
      File.write!(wedged, "")

      assert {:ok, message} = Server.tunnel(opts)
      assert message =~ "127.0.0.1:16444"
      assert_received {:forward, "127.0.0.1:16444:127.0.0.1:6443"}
    end

    test "takes a port no other installation's open tunnel holds, and keeps its own (#253, #285)",
         %{opts: opts, tmp_dir: tmp_dir} do
      test_pid = self()
      stub_tofu()
      home = Path.join(tmp_dir, "ehos")

      # acme's master answers on its control socket; beta's died in a reboot, leaving its record.
      stub(CommandRunnerMock, :run, fn
        "ssh", ["-S", socket, "-O", "check", "ubuntu@" <> _host] ->
          send(test_pid, {:check, socket})

          if socket == Path.join([home, "acme", "tunnel.sock"]),
            do: {"Master running (pid=42)", 0},
            else: {"Control socket connect: No such file or directory", 255}

        "sh", ["-c", _script, _log | args] ->
          send(test_pid, {:forward, Enum.at(args, -2)})
          {"", 0}

        "ssh", _args ->
          {@k3s_kubeconfig, 0}
      end)

      for {name, port} <- [{"acme", 16_443}, {"beta", 16_444}] do
        File.mkdir_p!(Path.join(home, name))
        record_tunnel(Path.join(home, name), port)
        File.write!(Path.join([home, name, "tunnel.sock"]), "")
      end

      # A record no tunnel writes, too large to be one, holds nothing.
      File.mkdir_p!(Path.join(home, "gamma"))

      File.write!(
        Path.join([home, "gamma", "tunnel.json"]),
        Jason.encode!(%{port: 16_445, padding: String.duplicate("x", 5000)})
      )

      # A record without a socket holds nothing either, and ssh is not asked about it.
      File.mkdir_p!(Path.join(home, "delta"))
      record_tunnel(Path.join(home, "delta"), 16_444)

      acme = Path.join(home, "acme")
      second = Keyword.put(opts, :name, "acme")
      File.write!(Path.join(acme, "server.tfvars.json"), "{}")
      File.write!(Path.join(acme, "installation.json"), ~s({"provider": "oci"}))

      assert {:ok, message} = Server.tunnel(opts)
      assert message =~ "127.0.0.1:16444"
      assert_received {:forward, "127.0.0.1:16444:127.0.0.1:6443"}
      beta = Path.join([home, "beta", "tunnel.sock"])
      assert_received {:check, ^beta}
      delta = Path.join([home, "delta", "tunnel.sock"])
      refute_received {:check, ^delta}

      # acme's own tunnel holds 16443 and is kept there, though trial's is open now.
      assert {:ok, message} = Server.tunnel(second)
      assert message =~ "127.0.0.1:16443"
      refute_received {:forward, _}
    end

    test "gives up its own port when its tunnel died and another's open tunnel holds it (#285)",
         %{opts: opts, dir: dir, tmp_dir: tmp_dir} do
      test_pid = self()
      stub_tofu()
      acme = Path.join([tmp_dir, "ehos", "acme"])

      stub(CommandRunnerMock, :run, fn
        "ssh", ["-S", socket, "-O", "check" | _] ->
          if socket == Path.join(acme, "tunnel.sock"),
            do: {"Master running (pid=42)", 0},
            else: {"Control socket connect: Connection refused", 255}

        "sh", ["-c", _script, _log | args] ->
          send(test_pid, {:forward, Enum.at(args, -2)})
          {"", 0}

        "ssh", _args ->
          {@k3s_kubeconfig, 0}
      end)

      # trial's master died in a reboot, leaving its record and socket; acme took 16443 since.
      record_tunnel(dir, 16_443)
      File.write!(Path.join(dir, "tunnel.sock"), "")
      File.mkdir_p!(acme)
      record_tunnel(acme, 16_443)
      File.write!(Path.join(acme, "tunnel.sock"), "")

      assert {:ok, message} = Server.tunnel(opts)
      assert message =~ "127.0.0.1:16444"
      assert_received {:forward, "127.0.0.1:16444:127.0.0.1:6443"}
    end

    test "never reads a tunnel's record from what is not a small regular file", %{
      opts: opts,
      tmp_dir: tmp_dir
    } do
      stub_tofu()
      home = Path.join(tmp_dir, "ehos")

      stub(CommandRunnerMock, :run, fn
        "ssh", ["-S", _socket, "-O", "check" | _] -> {"Master running (pid=42)", 0}
        "ssh", _args -> {@k3s_kubeconfig, 0}
        "sh", _args -> {"", 0}
      end)

      # Each would block, never end, or be a record that is not where it seems.
      for name <- ~w(fifo device link), do: File.mkdir_p!(Path.join(home, name))
      {_, 0} = System.cmd("mkfifo", [Path.join([home, "fifo", "tunnel.json"])])
      File.ln_s!("/dev/zero", Path.join([home, "device", "tunnel.json"]))
      record = Path.join(tmp_dir, "elsewhere.json")
      File.write!(record, Jason.encode!(%{address: @address, port: 16_443}))
      File.ln_s!(record, Path.join([home, "link", "tunnel.json"]))

      task = Task.async(fn -> Server.tunnel(opts) end)
      assert {:ok, {:ok, message}} = Task.yield(task, 10_000) || Task.shutdown(task)
      assert message =~ "127.0.0.1:16443"
    end

    test "opens the tunnel again when the open one goes to another port", %{opts: opts, dir: dir} do
      stub_tofu()
      record_tunnel(dir, 16_443)
      File.write!(Path.join(dir, "tunnel.sock"), "")
      test_pid = self()

      stub(CommandRunnerMock, :run, fn
        "ssh", ["-S", _socket, "-O", command | _] ->
          send(test_pid, {:control, command})
          {"", 0}

        "sh", ["-c", _script, _log | args] ->
          send(test_pid, {:forward, Enum.find(args, &String.ends_with?(&1, ":127.0.0.1:6443"))})
          {"", 0}

        "ssh", _args ->
          {@k3s_kubeconfig, 0}
      end)

      socket = Path.join(dir, "tunnel.sock")

      stub(CommandRunnerMock, :run, fn
        "ssh", ["-S", _socket, "-O", command | _] ->
          send(test_pid, {:control, command})
          {"", 0}

        "sh", ["-c", _script, _log | args] ->
          refute File.exists?(socket)
          send(test_pid, {:forward, Enum.find(args, &String.ends_with?(&1, ":127.0.0.1:6443"))})
          {"", 0}

        "ssh", _args ->
          {@k3s_kubeconfig, 0}
      end)

      assert {:ok, _message} = Server.tunnel(Keyword.put(opts, :port, 17_443))
      assert_received {:control, "exit"}
      assert_received {:forward, "127.0.0.1:17443:127.0.0.1:6443"}
      assert Jason.decode!(File.read!(Path.join(dir, "tunnel.json")))["port"] == 17_443
    end

    test "says when the tunnel's record cannot be written", %{opts: opts, dir: dir} do
      stub_tofu()
      File.mkdir_p!(Path.join(dir, "tunnel.json"))

      stub(CommandRunnerMock, :run, fn
        "ssh", ["-S" | _] -> {"", 255}
        "sh", _args -> {"", 0}
      end)

      assert {:error, message} = Server.tunnel(opts)
      assert message =~ "tunnel.json cannot be written" and message =~ "--close"
    end

    test "says what it cannot write instead of failing on the reason", %{opts: opts, dir: dir} do
      stub_tofu()
      record_tunnel(dir, 16_443)
      File.mkdir_p!(Path.join(dir, "kubeconfig"))

      stub(CommandRunnerMock, :run, fn
        "ssh", ["-S" | _] -> {"Master running", 0}
        "ssh", _args -> {@k3s_kubeconfig, 0}
      end)

      assert {:error, message} = Server.tunnel(opts)
      assert is_binary(message) and message =~ "cannot be written"
    end

    test "says why the tunnel did not open, from ssh's log", %{opts: opts, dir: dir} do
      stub_tofu()

      stub(CommandRunnerMock, :run, fn
        "ssh", ["-S" | _] ->
          {"", 255}

        "sh", ["-c", _script, log | _] ->
          File.write!(log, "bind [127.0.0.1]:16443: Address already in use\n")
          {"", 255}
      end)

      assert {:error, message} = Server.tunnel(opts)
      assert message =~ "Address already in use"
      refute File.exists?(Path.join(dir, "kubeconfig"))
    end

    test "never shows the kubeconfig when it cannot use it", %{opts: opts, dir: dir} do
      stub_tofu()
      record_tunnel(dir, 16_443)

      stub(CommandRunnerMock, :run, fn
        "ssh", ["-S" | _] -> {"Master running", 0}
        "ssh", _args -> {"client-key-data: S0VZ\nnot: [a kubeconfig", 0}
      end)

      assert {:error, message} = Server.tunnel(opts)
      refute message =~ "S0VZ"
    end

    test "says how to make the server when there is none", %{opts: opts} do
      assert {:error, message} = Server.tunnel(Keyword.put(opts, :name, "other"))
      assert message =~ "mix ehos.server up"
    end
  end

  describe "down/1" do
    test "closes the tunnel, destroys what the module made, and forgets the host key and kubeconfig",
         %{opts: opts, dir: dir} do
      test_pid = self()
      File.mkdir_p!(dir)

      for file <- ~w(server.tfvars.json known_hosts kubeconfig tunnel.sock),
          do: File.write!(Path.join(dir, file), "")

      File.write!(Path.join(dir, "installation.json"), ~s({"provider": "oci"}))

      expect(CommandRunnerMock, :run, fn "ssh", ["-S", _socket, "-O", "exit" | _] -> {"", 0} end)

      expect(CommandRunnerMock, :run_env, 2, fn "tofu", args, _env ->
        send(test_pid, {:tofu, args})
        {"", 0}
      end)

      assert {:ok, _message} = Server.down(opts)
      assert_received {:tofu, [_chdir, "init" | _]}

      assert_received {:tofu,
                       [_chdir, "destroy", "-input=false", "-auto-approve", "-var-file=" <> _ | _]}

      refute File.exists?(Path.join(dir, "known_hosts"))
      refute File.exists?(Path.join(dir, "kubeconfig"))
      assert File.exists?(Path.join(dir, "server.tfvars.json"))
    end

    test "on GCP, lifts the deletion protection from the server alone before it destroys", %{
      opts: opts,
      dir: dir
    } do
      test_pid = self()
      installation(dir, "gcp")

      stub(CommandRunnerMock, :run_env, fn "tofu", args, env ->
        send(test_pid, {:tofu, args, env})
        if lift?(args), do: {lift_json(), 0}, else: tofu(args)
      end)

      assert {:ok, _message} = Server.down(Keyword.delete(opts, :provider))
      ran = for {:tofu, [_chdir, command | args], env} <- drain(), do: {command, args, env}
      assert ["init", "plan", "show", "apply", "destroy"] = Enum.map(ran, &elem(&1, 0))

      assert {"plan", plan, plan_env} = List.keyfind(ran, "plan", 0)
      assert "-target=#{@gcp_instance}" in plan
      assert Enum.any?(plan, &String.starts_with?(&1, "-var-file="))
      assert {"TF_VAR_deletion_protection", "false"} in plan_env

      assert {"apply", apply, _env} = List.keyfind(ran, "apply", 0)
      assert Enum.any?(apply, &String.ends_with?(&1, "unprotect.tfplan"))

      assert {"destroy", _args, destroy_env} = List.keyfind(ran, "destroy", 0)
      assert {"TF_VAR_deletion_protection", "false"} in destroy_env
      refute File.exists?(Path.join(dir, "unprotect.tfplan"))
    end

    test "on GCP, lifts nothing from a server whose protection is not on", %{
      opts: opts,
      dir: dir
    } do
      test_pid = self()
      installation(dir, "gcp")

      # Off already, as after a lift in the console; or no server in the state at all.
      for json <- [
            lift_json(%{}, false),
            Jason.encode!(%{
              "resource_changes" => [
                %{
                  "address" => @gcp_instance,
                  "change" => %{"actions" => ["create"], "before" => nil, "after" => %{}}
                }
              ]
            })
          ] do
        stub(CommandRunnerMock, :run_env, fn "tofu", args, _env ->
          send(test_pid, {:tofu, args})
          if lift?(args), do: {json, 0}, else: tofu(args)
        end)

        assert {:ok, _message} = Server.down(Keyword.delete(opts, :provider))
        commands = for {:tofu, [_chdir, command | _args]} <- drain(), do: command
        assert "destroy" in commands
        refute "apply" in commands
      end
    end

    test "on GCP, refuses a lift that would change more than the protection, and destroys " <>
           "nothing",
         %{opts: opts, dir: dir} do
      test_pid = self()
      installation(dir, "gcp")

      for {json, named} <- [
            {lift_json(%{"machine_type" => "e2-standard-4"}), @gcp_instance},
            {lift_json(%{}, true, ["delete", "create"]), @gcp_instance},
            {lift_json(%{}, true, ["update"], ["update"]), "google_compute_firewall.ssh"},
            # A value the plan does not know until the apply, and a protection the plan keeps on.
            {lift_json(%{}, true, ["update"], ["no-op"], %{"machine_type" => true}),
             @gcp_instance},
            {lift_json(%{"deletion_protection" => true}), @gcp_instance},
            {lift_json(%{}, true, ["no-op"]), @gcp_instance}
          ] do
        stub(CommandRunnerMock, :run_env, fn "tofu", args, _env ->
          send(test_pid, {:tofu, args})
          if lift?(args), do: {json, 0}, else: tofu(args)
        end)

        assert {:error, message} = Server.down(Keyword.delete(opts, :provider))
        assert message =~ "would also change #{named}."

        assert message =~
                 "Turn off deletion_protection on the instance ehos-trial in Google Cloud"

        commands = for {:tofu, [_chdir, command | _args]} <- drain(), do: command
        refute "apply" in commands or "destroy" in commands
      end
    end

    test "on GCP, says the protection is lifted when the destroy fails after it", %{
      opts: opts,
      dir: dir
    } do
      installation(dir, "gcp")

      stub(CommandRunnerMock, :run_env, fn
        "tofu", [_chdir, "destroy" | _], _env -> {"Error: 503", 1}
        "tofu", args, _env -> if lift?(args), do: {lift_json(), 0}, else: tofu(args)
      end)

      assert {:error, message} = Server.down(Keyword.delete(opts, :provider))
      assert message =~ "Error: 503"

      assert message =~
               "The deletion protection is lifted from ehos-trial; run `mix ehos.server down`"

      assert message =~ "again to finish removing it"
    end

    test "on AWS, whose provider lifts its own protection, and Oracle, destroys at once", %{
      opts: opts,
      dir: dir
    } do
      test_pid = self()

      for provider <- ["aws", "oci"] do
        installation(dir, provider)

        stub(CommandRunnerMock, :run_env, fn "tofu", args, env ->
          send(test_pid, {:tofu, args, env})
          tofu(args)
        end)

        assert {:ok, _message} = Server.down(Keyword.delete(opts, :provider))
        ran = for {:tofu, [_chdir, command | _args], env} <- drain(), do: {command, env}
        assert ["init", "destroy"] = Enum.map(ran, &elem(&1, 0))
      end
    end

    test "keeps the host key when the destroy fails", %{opts: opts, dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "server.tfvars.json"), "{}")
      File.write!(Path.join(dir, "installation.json"), ~s({"provider": "oci"}))
      File.write!(Path.join(dir, "known_hosts"), "")

      stub(CommandRunnerMock, :run_env, fn
        "tofu", [_chdir, "init" | _], _env -> {"", 0}
        "tofu", [_chdir, "destroy" | _], _env -> {"Error: 409-Conflict", 1}
      end)

      assert {:error, message} = Server.down(opts)
      assert message =~ "409-Conflict"
      assert File.exists?(Path.join(dir, "known_hosts"))
    end
  end

  describe "close_tunnel/1" do
    test "says so when no tunnel is open", %{opts: opts} do
      assert {:ok, "No tunnel to ehos-trial is open"} = Server.close_tunnel(opts)
    end

    test "closes the tunnel through its control socket, and forgets where it went", %{
      opts: opts,
      dir: dir
    } do
      File.mkdir_p!(dir)
      record_tunnel(dir, 16_443)
      File.write!(Path.join(dir, "tunnel.sock"), "")

      expect(CommandRunnerMock, :run, fn "ssh", ["-S", _socket, "-O", "exit" | _] -> {"", 0} end)

      assert {:ok, "The tunnel to ehos-trial is closed"} = Server.close_tunnel(opts)
      refute File.exists?(Path.join(dir, "tunnel.json"))
    end
  end

  describe "status/1" do
    setup %{dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "server.tfvars.json"), "{}")
      File.write!(Path.join(dir, "installation.json"), ~s({"provider": "oci"}))
      :ok
    end

    test "shows the server's address, its CPUs, memory and load, its first boot and its node",
         %{opts: opts} do
      stub_tofu()

      expect(CommandRunnerMock, :run, fn "ssh", args ->
        script = List.last(args)
        assert script =~ "nproc" and script =~ "/proc/meminfo" and script =~ "/proc/loadavg"
        assert script =~ "cloud-init status; sudo k3s kubectl get nodes -o wide"

        {"cpus 2\nMemTotal: 12249180\nMemAvailable: 10276344\nload 0.15 0.10 0.05\n---\n" <>
           "status: done\nNAME   STATUS\nehos   Ready\n", 0}
      end)

      assert {:ok, message} = Server.status(opts)

      assert message == """
             ehos-trial at #{@address}
             CPU: 2, load 0.15 0.10 0.05 (1, 5 and 15 minutes)
             Memory: 9.8 GiB available of 11.7 GiB
             status: done
             NAME   STATUS
             ehos   Ready
             """
    end

    test "reports the node's resources when Kubernetes does not answer", %{opts: opts} do
      stub_tofu()

      expect(CommandRunnerMock, :run, fn "ssh", _args ->
        {"cpus 2\nMemTotal: 12249180\nMemAvailable: 10276344\nload 0.01 0.02 0.03\n---\n" <>
           "status: done\nThe connection to the server 127.0.0.1:6443 was refused\n" <>
           "Kubernetes did not answer.\n", 0}
      end)

      assert {:ok, message} = Server.status(opts)
      assert message =~ "Memory: 9.8 GiB available of 11.7 GiB"
      assert message =~ "Kubernetes did not answer."
    end

    test "says what it could not read of the node's resources, whatever else was printed" do
      assert Server.status_report("cpus x\n---\nstatus: done\n") ==
               "CPU: not read\nMemory: not read\nstatus: done\n"

      # A shell's startup file can print a line of its own, or a carriage return.
      assert Server.status_report("cpus 2\n  \r\nload 1 2 3\n---\nstatus: done\n") ==
               "CPU: 2, load 1 2 3 (1, 5 and 15 minutes)\nMemory: not read\nstatus: done\n"
    end

    test "names the command the operator runs, as it is given" do
      opts = [name: "trial", home: "/nonexistent", passphrase: String.duplicate("p", 16)]

      assert {:error, message} =
               Server.status(Keyword.merge(opts, command: "ehosctl server"))

      assert message =~
               "Make it with `ehosctl server up --provider PROVIDER`, PROVIDER one of aws, gcp, oci, ovh"
    end

    test "names the installation in the commands it suggests, when the caller asks" do
      opts = [name: "trial", home: "/nonexistent", passphrase: String.duplicate("p", 16)]

      named =
        Keyword.merge(opts,
          command: "ehosctl server",
          name_option: "--installation",
          name_in_commands: true
        )

      assert {:error, message} = Server.status(named)

      assert message =~
               "Make it with `ehosctl server up --provider PROVIDER --installation trial`, PROVIDER one of"

      assert {:error, message} = Server.status(opts)
      assert message =~ "Make it with `mix ehos.server up --provider PROVIDER`"
    end

    test "says to admit this machine's address again when SSH does not answer", %{opts: opts} do
      stub_tofu()
      expect(CommandRunnerMock, :run, fn "ssh", _args -> {"Operation timed out", 255} end)

      assert {:error, message} = Server.status(opts)
      assert message =~ "run `mix ehos.server up` again"
    end
  end

  describe "remote/2" do
    test "runs a command on the server over SSH and returns its output and status, failures included",
         %{opts: opts, dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "server.tfvars.json"), "{}")
      File.write!(Path.join(dir, "installation.json"), ~s({"provider": "oci"}))
      stub_tofu()

      expect(CommandRunnerMock, :run, 2, fn "ssh", args ->
        assert "ubuntu@#{@address}" in args
        assert "UserKnownHostsFile=#{Path.join(dir, "known_hosts")}" in args

        case List.last(args) do
          "cat /proc/sys/kernel/random/boot_id" -> {"b1\n", 0}
          "sudo systemctl reboot" -> {"Connection closed", 255}
        end
      end)

      assert {:ok, {"b1\n", 0}} = Server.remote(opts, "cat /proc/sys/kernel/random/boot_id")
      assert {:ok, {"Connection closed", 255}} = Server.remote(opts, "sudo systemctl reboot")
    end

    test "reaches an address it is given without reading OpenTofu's state", %{
      opts: opts,
      dir: dir
    } do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "server.tfvars.json"), "{}")
      File.write!(Path.join(dir, "installation.json"), ~s({"provider": "oci"}))

      expect(CommandRunnerMock, :run, fn "ssh", args ->
        assert "ubuntu@198.51.100.9" in args
        {"", 0}
      end)

      assert {:ok, {"", 0}} = Server.remote(Keyword.put(opts, :address, "198.51.100.9"), "true")
    end

    test "says how to make the server when there is none", %{opts: opts} do
      assert {:error, message} = Server.remote(opts, "true")
      assert message =~ "mix ehos.server up"
    end
  end

  describe "host_key_fingerprints/2" do
    test "prints the address's keys as ssh-keygen -l does, and nothing for other hosts",
         %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "known_hosts")
      key = "AAAAC3NzaC1lZDI1NTE5AAAAIHJW8mIz6TFSkLmac1HAw5DFrXN80G7PEP11G/LYZ4qF"
      File.write!(path, "192.0.2.9 ssh-ed25519 #{key}\n203.0.113.7 ssh-ed25519 #{key}\n")

      {listed, 0} = System.cmd("ssh-keygen", ["-l", "-F", "203.0.113.7", "-f", path])
      [_, expected] = Regex.run(~r/(SHA256:\S+)/, listed)

      assert Server.host_key_fingerprints(path, "203.0.113.7") == ["ssh-ed25519 #{expected}"]
      assert Server.host_key_fingerprints(path, "198.51.100.1") == []
      assert Server.host_key_fingerprints(Path.join(tmp_dir, "none"), "203.0.113.7") == []
    end
  end

  describe "rewrite_kubeconfig/3" do
    test "refuses anything but one cluster and one user" do
      assert {:error, _} =
               Server.rewrite_kubeconfig("clusters: []\nusers: []\n", "ehos-trial", 16_443)

      assert {:error, _} = Server.rewrite_kubeconfig("[", "ehos-trial", 16_443)
    end
  end

  # What `tofu` answers when nothing goes wrong: a plan that removes nothing, and the server's
  # address.
  defp tofu(args) do
    cond do
      "output" in args -> {@outputs, 0}
      "show" in args -> {plan_json(["update"]), 0}
      true -> {"", 0}
    end
  end

  # A plan that updates the firewall and does `instance_actions` to the server, whose attributes
  # are `before` and `after` it.
  defp plan_json(
         instance_actions,
         instance \\ "oci_core_instance.server",
         before \\ %{},
         after_ \\ %{}
       ) do
    Jason.encode!(%{
      "resource_changes" => [
        %{"address" => "oci_core_security_list.this", "change" => %{"actions" => ["update"]}},
        %{
          "address" => instance,
          "change" => %{"actions" => instance_actions, "before" => before, "after" => after_}
        }
      ]
    })
  end

  # An Oracle instance's attributes, as a plan shows them, with a flex shape of that size.
  defp shape(ocpus, memory),
    do: %{
      "shape_config" => [%{"ocpus" => ocpus, "memory_in_gbs" => memory, "vcpus" => 2 * ocpus}]
    }

  # OpenTofu on a server that exists: the plan's attributes before are what the last apply made,
  # and after them the size in the variables, else the module's default of 2 OCPUs and 12 GB; an
  # SSH key or a firewall rule changed besides, so the instance is always updated.
  defp stub_oracle_server do
    stub(CommandRunnerMock, :run_env, fn
      "tofu", [_chdir, "plan" | args] = all, _env ->
        "-var-file=" <> path = Enum.find(args, &String.starts_with?(&1, "-var-file="))
        vars = path |> File.read!() |> Jason.decode!()
        Process.put(:planned, shape(vars["ocpus"] || 2, vars["memory_gbs"] || 12))
        tofu(all)

      "tofu", [_chdir, "show" | _], _env ->
        before = Process.get(:applied, shape(2, 12))
        {plan_json(["update"], "oci_core_instance.server", before, Process.get(:planned)), 0}

      "tofu", [_chdir, "apply", "-input=false", "-auto-approve" | _] = args, _env ->
        Process.put(:applied, Process.get(:planned))
        tofu(args)

      "tofu", args, _env ->
        tofu(args)
    end)
  end

  defp record_tunnel(dir, port),
    do:
      File.write!(Path.join(dir, "tunnel.json"), Jason.encode!(%{address: @address, port: port}))

  defp stub_tofu do
    stub(CommandRunnerMock, :run_env, fn "tofu", args, _env ->
      tofu(args)
    end)
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  # GCP's options, for `up` on GCP, with `extra`.
  defp gcp(opts, extra),
    do: Keyword.merge(opts, [provider: "gcp", gcp_project: "p", name: "gcpx"] ++ extra)

  # Whether OpenTofu is asked to show the lift's plan.
  defp lift?(args),
    do: "show" in args and Enum.any?(args, &String.ends_with?(&1, "unprotect.tfplan"))

  # A lift's plan: the GCP instance's deletion protection from `protected` to false, its other
  # attributes changed by `changed` or not known until the apply by `unknown`, with the instance's
  # `actions` and a firewall's `firewall`.
  defp lift_json(
         changed \\ %{},
         protected \\ true,
         actions \\ ["update"],
         firewall \\ ["no-op"],
         unknown \\ %{}
       ) do
    before = %{
      "deletion_protection" => protected,
      "machine_type" => "e2-standard-2",
      "name" => "x"
    }

    Jason.encode!(%{
      "resource_changes" => [
        %{"address" => "google_compute_firewall.ssh", "change" => %{"actions" => firewall}},
        %{
          "address" => @gcp_instance,
          "change" => %{
            "actions" => actions,
            "before" => before,
            "after" =>
              before
              |> Map.put("deletion_protection", false)
              |> Map.merge(changed)
              |> Map.drop(Map.keys(unknown)),
            "after_unknown" => unknown
          }
        }
      ]
    })
  end

  # An installation `up` made on `provider`, with nothing open to it.
  defp installation(dir, provider) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "server.tfvars.json"), "{}")
    File.write!(Path.join(dir, "installation.json"), Jason.encode!(%{"provider" => provider}))
  end

  defp drain(acc \\ []) do
    receive do
      message -> drain([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "detect_addresses/2" do
    # ehos-tools#157: each service is asked more than once, and every address any gave is kept.
    test "keeps every address the services gave, once each, in the order first seen" do
      {:ok, seen} = Agent.start_link(fn -> [] end)

      expect(PublicAddressMock, :ask, 6, fn service ->
        n = Agent.get_and_update(seen, &{length(&1), [service | &1]})
        if rem(n, 2) == 0, do: {:ok, "77.65.103.58"}, else: {:ok, "83.8.86.65"}
      end)

      assert {:ok, addresses} = Server.detect_addresses(PublicAddressMock)
      assert Enum.sort(addresses) == ["77.65.103.58", "83.8.86.65"]

      services = Agent.get(seen, & &1)
      assert length(Enum.uniq(services)) == 3
    end

    test "leaves out a service that fails while another answers" do
      stub(PublicAddressMock, :ask, fn
        "https://checkip.amazonaws.com" -> {:error, "timeout"}
        _service -> {:ok, "198.51.100.4"}
      end)

      assert Server.detect_addresses(PublicAddressMock) == {:ok, ["198.51.100.4"]}
    end

    test "counts an ask that takes too long as that service's failure" do
      stub(PublicAddressMock, :ask, fn
        "https://api.ipify.org" -> {:ok, "198.51.100.4"}
        _service -> Process.sleep(:infinity)
      end)

      {elapsed_us, result} = :timer.tc(fn -> Server.detect_addresses(PublicAddressMock, 200) end)
      assert result == {:ok, ["198.51.100.4"]}
      # The asks wait together, not in turns of the machine's cores.
      assert elapsed_us < 400_000

      stub(PublicAddressMock, :ask, fn _service -> Process.sleep(:infinity) end)
      assert {:error, reason} = Server.detect_addresses(PublicAddressMock, 50)
      assert reason =~ "checkip.amazonaws.com: it did not answer in time"
    end

    # ehos-tools#544: the crash stops neither this process nor, through the task's link, kills it.
    test "counts an ask that crashed as that service's failure, and says nothing of why" do
      stub(PublicAddressMock, :ask, fn
        "https://api.ipify.org" -> {:ok, "198.51.100.4"}
        _service -> raise "fixture crash"
      end)

      assert Server.detect_addresses(PublicAddressMock) == {:ok, ["198.51.100.4"]}

      stub(PublicAddressMock, :ask, fn _service -> raise "fixture crash" end)

      assert Server.detect_addresses(PublicAddressMock) ==
               {:error,
                "checkip.amazonaws.com: its ask failed; api.ipify.org: its ask failed; " <>
                  "ipv4.icanhazip.com: its ask failed"}
    end

    # A caller that traps exits, as ehosctl does, gets the task's death as a message.
    test "counts a task killed by a process linked to it as that service's failure" do
      Process.flag(:trap_exit, true)

      stub(PublicAddressMock, :ask, fn
        "https://api.ipify.org" ->
          {:ok, "198.51.100.4"}

        _service ->
          spawn_link(fn -> exit(:fixture_reason) end)
          Process.sleep(:infinity)
      end)

      assert Server.detect_addresses(PublicAddressMock) == {:ok, ["198.51.100.4"]}
    end

    test "names each service's failure when none answers" do
      stub(PublicAddressMock, :ask, fn _service -> {:error, "timeout"} end)

      assert Server.detect_addresses(PublicAddressMock) ==
               {:error,
                "checkip.amazonaws.com: timeout; api.ipify.org: timeout; ipv4.icanhazip.com: timeout"}
    end
  end

  defp drain_messages(acc \\ []) do
    receive do
      message -> drain_messages([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
