defmodule EhosPlatform.ServerTest do
  use ExUnit.Case, async: true

  import Hammox
  import EhosPlatform.TestSupport

  alias EhosPlatform.ClockMock
  alias EhosPlatform.CommandRunnerMock
  alias EhosPlatform.EnvMock
  alias EhosPlatform.PublicAddressMock
  alias EhosPlatform.Report
  alias EhosPlatform.Secret
  alias EhosPlatform.Server
  alias EhosPlatform.Server.Administrators
  alias EhosPlatform.Server.ClientCertificate
  alias EhosPlatform.Shell
  alias EhosPlatform.Source
  alias EhosPlatform.TestCA

  doctest Server

  setup :verify_on_exit!

  # The operator's home as the system has it, which no test creates: a key under it is one the
  # test names, never one this machine's operator keeps.
  @system_home "/home/operator"

  # SSH control commands (`-O`) run bounded, without the operator's ssh config (eh-os#291); the
  # tests below match them as the commands they are, through `run`.
  setup do
    stub(CommandRunnerMock, :run_bounded, fn "ssh", ["-F", "none" | args], 5_000 ->
      CommandRunnerMock.run("ssh", args)
    end)

    # The environment holds nothing a test does not set, the system puts the operator's home at
    # @system_home, nothing waits, and this machine leaves through one address.
    stub(EnvMock, :get, fn _name -> nil end)
    stub(EnvMock, :user_home, fn -> @system_home end)
    stub(ClockMock, :sleep, fn _ms -> :ok end)
    stub(ClockMock, :utc_now, fn -> ~U[2026-11-19 12:00:00Z] end)
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

  # What `up` and `tunnel` warn of a server whose lines name no person.
  @no_administrator_warning {"No installation administrator has access of their own.",
                             "Add each person with `admin add`, with a new key of their own."}

  # The line cloud-init writes for the key this workstation logs in with, `ssh_key`'s `.pub`.
  @operator_line "ssh-ed25519 AAAAb3A= operator\n"

  # The same key, named as the key that every administrator shares, as on a server not moved yet.
  @shared_line "ssh-ed25519 AAAAb3A= ehos-administrator:shared\n"

  # What `up` runs over SSH after the first boot to read the installation administrators (eh-os
  # D-199), as `EhosPlatform.Server.Administrators` holds it.
  @administrators_read ~S"""
  f="$HOME/.ssh/authorized_keys"
  e=$(mktemp) || exit 3
  trap 'rm -f "$e"' EXIT
  if [ -e "$f" ]; then sha256sum <"$f" | cut -d' ' -f1 && base64 -w0 <"$f" || exit 4; else echo none; fi
  for kinds in clusterrolebindings,rolebindings clusterroles,roles certificatesigningrequests; do
    printf '\n%s\n' '--- ehosctl administrators ---'
    sudo k3s kubectl get --request-timeout=30s "$kinds" --all-namespaces -o json 2>"$e" || { cat "$e"; exit 3; }
  done
  """

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

    # What `server_up/1` and `tunnel_open/2` expect a report to name, unless a test gives another.
    Process.put(:home, home)
    Process.put(:ssh_key, key)

    %{opts: opts, dir: Path.join(home, "trial")}
  end

  describe "every command" do
    # T-20 replaced these options with modules.
    test "refuses an option that is no longer taken, saying which module to give", %{
      opts: opts
    } do
      mock_nothing_run()

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
      mock_nothing_run()
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
        assert command.(Keyword.put(opts, :passphrase, passphrase)) ==
                 {:error,
                  "Set EHOS_STATE_PASSPHRASE to the passphrase of this installation's state, at " <>
                    "least 16 characters. It encrypts OpenTofu's state (D-77); keep it where you " <>
                    "keep passwords"}
      end
    end

    test "refuses to make a server on no provider, naming each, before running anything", %{
      opts: opts,
      dir: dir
    } do
      assert Server.up(Keyword.delete(opts, :provider)) == {:error, no_provider()}

      assert Server.provider_named(Keyword.delete(opts, :provider)) ==
               {:error, :invalid, no_provider()}

      refute File.exists?(dir)

      # Variables with no recorded provider, as an older `up` that stopped early left them.
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "server.tfvars.json"), ~s({"name": "trial"}))

      remote = &Server.remote(&1, "true")

      for command <- [&Server.down/1, &Server.tunnel/1, &Server.status/1, remote] do
        assert command.(Keyword.delete(opts, :provider)) ==
                 {:error,
                  "No installation trial in #{dir}. Make it with `mix ehos.server up --provider " <>
                    "PROVIDER`, PROVIDER one of aws, gcp, oci, ovh"}
      end
    end

    # ehos-tools#345: an installation is made once `up` recorded where; variables alone, as an older
    # `up` that stopped before anything was made left them, are not one, whatever --provider says.
    test "takes variables without a recorded place for no installation, even with a provider", %{
      opts: opts,
      dir: dir
    } do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "server.tfvars.json"), "{}")
      refute Server.made?(opts)

      for command <- [&Server.down/1, &Server.tunnel/1, &Server.status/1] do
        assert command.(opts) ==
                 {:error,
                  "No installation trial in #{dir}. Make it with `mix ehos.server up --provider " <>
                    "PROVIDER`, PROVIDER one of aws, gcp, oci, ovh"}
      end

      # A state too, and still no record: the record was lost. It is listed, so its commands say
      # to restore the record, and `up` refuses rather than plan from this command's options.
      File.write!(Path.join(dir, "terraform.tfstate"), "encrypted")
      assert Server.made?(opts)

      lost =
        "#{dir}/installation.json is missing, though #{dir} holds a state: restore it from " <>
          "where it was kept, since it says which provider, account and region the server is " <>
          "in. Running `up` without it could make a server in another place than the first's"

      for command <- [&Server.down/1, &Server.status/1, &Server.up/1] do
        assert command.(Keyword.put(opts, :provider, "aws")) == {:error, lost}
      end

      assert Server.provider_named(Keyword.put(opts, :provider, "aws")) == {:error, :failed, lost}
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

      assert Server.provider_named(opts) ==
               {:error, :failed,
                "#{dir}/installation.json cannot be read as an installation's place; restore it"}
    end

    test "refuses a name OpenTofu's module would refuse", %{opts: opts} do
      for name <- ["Trial_1", "trial\n", "../trial"] do
        refused = "The installation's name is 2 to 16 lowercase letters, digits and hyphens"
        assert Server.up(Keyword.put(opts, :name, name)) == {:error, refused}

        assert Server.provider_named(Keyword.put(opts, :name, name)) ==
                 {:error, :invalid, refused}
      end
    end
  end

  describe "ssh_cidr/1" do
    test "reads an address alone as /32 and a CIDR block as given" do
      assert Server.ssh_cidr("83.8.86.65") == {:ok, "83.8.86.65/32"}
      assert Server.ssh_cidr("83.8.86.65/32") == {:ok, "83.8.86.65/32"}
      assert Server.ssh_cidr("172.16.0.0/16") == {:ok, "172.16.0.0/16"}
    end

    test "refuses a block wider than /16" do
      for value <- ["128.0.0.0/1", "10.0.0.0/8", "172.16.0.0/15"] do
        assert Server.ssh_cidr(value) ==
                 {:error,
                  "--ssh-from #{value} is wider than /16, 65,536 addresses; give the block " <>
                    "your network leaves through, /16 or narrower"}
      end
    end

    test "refuses host bits, naming the block and the address either could mean" do
      assert Server.ssh_cidr("83.8.86.65/24") ==
               {:error,
                "--ssh-from 83.8.86.65/24 has host bits set; give the block as 83.8.86.0/24, or " <>
                  "the address alone as 83.8.86.65/32"}
    end

    test "refuses IPv6, which no module admits SSH over" do
      for value <- ["2001:db8::1", "2001:db8::/32", "::ffff:192.0.2.1"] do
        assert Server.ssh_cidr(value) ==
                 {:error,
                  "--ssh-from #{value} is IPv6; the server is reached over IPv4 alone, so give " <>
                    "the IPv4 address SSH comes from"}
      end
    end

    test "refuses the whole internet" do
      assert Server.ssh_cidr("0.0.0.0/0") ==
               {:error,
                "--ssh-from 0.0.0.0/0 admits the whole internet; give the addresses SSH comes from"}
    end

    test "refuses a prefix length written other than as a plain number, saying how to write it" do
      for {value, prefix} <- [{"192.0.2.0/024", "024"}, {"192.0.2.0/+24", "+24"}] do
        assert Server.ssh_cidr(value) ==
                 {:error,
                  "--ssh-from #{value} writes its prefix length as #{prefix}; write it as 24"}
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
        assert Server.ssh_cidr(value) ==
                 {:error,
                  "--ssh-from #{value} is not an IPv4 address or CIDR block, such as 192.0.2.4 " <>
                    "or 192.0.2.0/24"}
      end
    end
  end

  describe "up/1" do
    test "writes the variables, applies the module with the state encrypted, and waits for k3s",
         %{opts: opts, dir: dir, tmp_dir: tmp_dir} do
      mock_tofu()
      # sshd is not up on the first try; the second sees cloud-init done.
      mock_ssh_up_on_second_try()

      assert Server.up(opts) == server_up()

      env = [
        {"TF_VAR_state_passphrase", @passphrase},
        {"TF_VAR_deletion_protection", nil},
        {"TF_DATA_DIR", "#{dir}/tofu"},
        {"TF_PLUGIN_CACHE_DIR", "#{tmp_dir}/ehos/plugin-cache"},
        {"TF_IN_AUTOMATION", "1"},
        {"TF_CLI_ARGS", nil},
        {"TF_CLI_ARGS_init", nil},
        {"TF_CLI_ARGS_plan", nil},
        {"TF_CLI_ARGS_apply", nil},
        {"TF_CLI_ARGS_destroy", nil},
        {"TF_CLI_ARGS_output", nil},
        {"TF_CLI_ARGS_show", nil}
      ]

      cloud_init = "cloud-init status --wait >/dev/null; cloud-init status --long"

      # Planned from the variables beside the recorded ones, which they replace once applied.
      assert drain() == [
               {:tofu, tofu_init(dir), env},
               {:tofu, tofu_plan(dir), env},
               {:tofu, tofu_show(dir), env},
               {:tofu, tofu_apply(dir), env},
               {:tofu, tofu_output(), env},
               {:ssh, ssh_args(tmp_dir, dir, cloud_init)},
               {:ssh, ssh_args(tmp_dir, dir, cloud_init)},
               {:ssh, ssh_args(tmp_dir, dir, @administrators_read)}
             ]

      refute File.exists?(Path.join(dir, "server.tfvars.json.next"))

      assert vars(dir) == %{
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
    end

    test "names the passphrase, the state and the SSH key, as not new when the plan changes nothing",
         %{opts: opts} do
      mock_tofu(%{"show" => {unchanged_plan(), 0}})
      mock_ssh_up_on_second_try()

      assert Server.up(opts) == server_up("trial", changed?: false)
    end

    # eh-os D-124: a server made with an ephemeral address gets a reserved one, a new address, once.
    test "says when the server's address changed, and how the console's host follows it", %{
      opts: opts,
      dir: dir
    } do
      for {before, said} <- [{"192.0.2.1", [address_changed()]}, {@address, []}, {nil, []}] do
        # Each a server of its own: what a stopped run kept for the next is not carried over.
        File.rm(Path.join(dir, "previous_address"))
        mock_tofu(%{"show" => {plan_from(before), 0}})
        # Said before the server is reached, so a run that fails at SSH says it too.
        mock_ssh("Connection refused", 1)

        assert Server.up(with_progress(opts)) == first_boot_failed("Connection refused")
        assert progress() == [making()] ++ said
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
      mock_tofu(%{"show" => {plan_from("192.0.2.1"), 0}})
      mock_ssh("status: done\n", 0)
      assert Server.up(opts) == server_up()

      assert File.read!(known) ==
               "192.0.2.1 ssh-ed25519 AAAAold\n#{@address} ssh-ed25519 AAAAold\n"

      # Carried once: a second run adds nothing.
      assert Server.up(opts) == server_up()

      assert File.read!(known) ==
               "192.0.2.1 ssh-ed25519 AAAAold\n#{@address} ssh-ed25519 AAAAold\n"

      mock_ssh("Host key verification failed.\r\n", 255)

      assert Server.up(opts) ==
               {:error,
                "The server at #{@address} answered SSH with another host key than the one " <>
                  "recorded for ehos-trial. The module was applied, but nothing was run on the " <>
                  "server. Compare the keys with the console history of the instance in Oracle's " <>
                  "console before trusting it:\nHost key verification failed.\r\n"}
    end

    test "says which file it cannot carry the old address's host key into", %{
      opts: opts,
      dir: dir
    } do
      known = Path.join(dir, "known_hosts")
      File.mkdir_p!(dir)
      File.write!(known, "192.0.2.1 ssh-ed25519 AAAAold\n")
      File.chmod!(known, 0o400)
      mock_tofu(%{"show" => {plan_from("192.0.2.1"), 0}})

      assert Server.up(opts) == {:error, "#{known} cannot be written: permission denied"}
      File.chmod!(known, 0o600)
      assert File.read!(known) == "192.0.2.1 ssh-ed25519 AAAAold\n"
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

      mock_tofu(%{"show" => {plan_from("192.0.2.1"), 0}})
      mock_ssh("Connection refused", 1)
      assert Server.up(opts) == first_boot_failed("Connection refused")
      assert File.read!(kept) == "192.0.2.1\n"

      # The state holds the new address now: the plan sees none changed.
      mock_tofu(%{"show" => {plan_from(@address), 0}})
      mock_ssh("status: done\n", 0)
      _ = drain()
      assert Server.up(with_progress(opts)) == server_up()
      assert progress() == [making(), address_changed()]

      assert File.read!(Path.join(dir, "known_hosts")) ==
               "192.0.2.1 ssh-ed25519 AAAAold\n#{@address} ssh-ed25519 AAAAold\n"

      refute File.exists?(kept)
    end

    test "never puts the passphrase on a command line", %{opts: opts} do
      mock_tofu()
      mock_ssh("status: done\n", 0)

      assert Server.up(opts) == server_up()

      args =
        for call <- drain(),
            arg <- elem(call, 1),
            String.contains?(arg, @passphrase),
            do: arg

      assert args == []
    end

    test "replaces the server when asked to, forgetting its host key and kubeconfig", %{
      opts: opts,
      dir: dir
    } do
      File.mkdir_p!(dir)
      for file <- ~w(known_hosts kubeconfig), do: File.write!(Path.join(dir, file), "old")
      mock_tofu(%{"show" => {plan_json(["delete", "create"]), 0}})
      mock_ssh("status: done\n", 0)

      assert Server.up(Keyword.put(opts, :replace, true)) == server_up()

      assert tofu_runs() == [
               tofu_init(dir),
               tofu_plan(dir, "oci", ["-replace=oci_core_instance.server"]),
               tofu_show(dir),
               tofu_apply(dir),
               tofu_output()
             ]

      refute File.exists?(Path.join(dir, "kubeconfig"))
      refute File.exists?(Path.join(dir, "known_hosts"))
    end

    test "reads a plan past a warning that holds braces of its own", %{opts: opts} do
      mock_tofu_warning("Warning: argument \"${var.x}\" is deprecated {see docs}\n", """

      Warning: { trailing }
      """)

      mock_ssh("status: done\n", 0)

      assert Server.up(opts) == server_up()
    end

    test "keeps the availability domain it used before unless told another", %{
      opts: opts,
      dir: dir
    } do
      mock_tofu()
      mock_ssh("status: done\n", 0)

      assert Server.up(Keyword.put(opts, :availability_domain, 2)) == server_up()
      assert vars(dir) == oci_vars(%{"availability_domain" => 2})
      assert Server.up(opts) == server_up()
      assert vars(dir) == oci_vars(%{"availability_domain" => 2})
      assert Server.up(Keyword.put(opts, :availability_domain, 1)) == server_up()
      assert vars(dir) == oci_vars(%{"availability_domain" => 1})
    end

    # eh-os D-158: port 53, for acme-dns, once asked for; never named to a module before then.
    test "opens port 53 for public certificates when told, and keeps it",
         %{opts: opts, dir: dir, tmp_dir: tmp_dir} do
      opts = Keyword.put(opts, :source, modules(tmp_dir, ~s(variable "public_certificates" {})))
      mock_tofu()
      mock_ssh("status: done\n", 0)

      assert Server.up(opts) == server_up()
      refute Map.has_key?(vars(dir), "public_certificates")
      assert Server.up(Keyword.put(opts, :public_certificates, true)) == server_up()
      assert vars(dir) == oci_vars(%{"public_certificates" => true})
      assert Server.up(opts) == server_up()
      assert vars(dir) == oci_vars(%{"public_certificates" => true})
    end

    # ehos-tools#891: OpenTofu only warns of a variable its module does not declare, and a module
    # from before EHOS 0.27.0 kept port 53 closed while `up` succeeded.
    test "refuses public certificates with modules that cannot open port 53, changing nothing",
         %{opts: opts, dir: dir, tmp_dir: tmp_dir} do
      opts = Keyword.put(opts, :source, modules(tmp_dir, ~s(variable "ssh_from" {})))
      mock_nothing_run()

      refusal =
        "ehos-trial is not changed. Its OpenTofu modules cannot open port 53, which public " <>
          "certificates need: they come from an EHOS release before 0.27.0. "

      assert Server.up(Keyword.put(opts, :public_certificates, true)) ==
               {:error,
                refusal <>
                  "Run `mix ehos.server up --public-certificates` with the modules of EHOS " <>
                  "0.27.0 or later"}

      assert Server.up(
               opts
               |> Keyword.put(:public_certificates, true)
               |> Keyword.merge(
                 command: "ehosctl server",
                 release_option: "--version",
                 name_option: "--installation",
                 name_in_commands: true
               )
             ) ==
               {:error,
                refusal <>
                  "Run `ehosctl server up --public-certificates --version <0.27.0 or later> " <>
                  "--installation trial`"}

      refute File.exists?(Path.join(dir, "server.tfvars.json"))
    end

    test "says that it needs a source, to ask its modules about port 53", %{opts: opts} do
      mock_nothing_run()

      assert_raise ArgumentError, "OpenTofu runs on a source's modules: pass :source", fn ->
        opts |> Keyword.delete(:source) |> Keyword.put(:public_certificates, true) |> Server.up()
      end
    end

    # The same once an earlier `up` recorded the flag, which the old modules ignored.
    test "refuses modules that cannot open port 53 once public certificates are recorded",
         %{opts: opts, dir: dir, tmp_dir: tmp_dir} do
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, "server.tfvars.json"),
        Jason.encode!(oci_vars(%{"public_certificates" => true}))
      )

      mock_nothing_run()

      assert {:error, "ehos-trial is not changed. Its OpenTofu modules cannot open port 53" <> _} =
               Server.up(Keyword.put(opts, :source, modules(tmp_dir, "")))
    end

    # D-84: a server is resized in place.
    test "keeps the size it used before unless told another, and says a server is resized",
         %{opts: opts, dir: dir} do
      mock_oracle_server()
      mock_ssh("status: done\n", 0)
      opts = with_progress(opts)

      # Nothing asked is the module's default, which the variables leave to it.
      assert Server.up(opts) == server_up()
      assert vars(dir) == oci_vars()
      assert progress() == [making()]

      assert Server.up(Keyword.merge(opts, ocpus: 1, memory_gb: 6)) == server_up()
      assert vars(dir) == oci_vars(%{"ocpus" => 1, "memory_gbs" => 6})

      assert progress() == [
               making(),
               {:step,
                "Resizing ehos-trial (ocpus 2 → 1, memory_in_gbs 12 → 6): the provider stops " <>
                  "and starts it, and its disk and address stay"}
             ]

      assert Server.up(opts) == server_up()
      assert vars(dir) == oci_vars(%{"ocpus" => 1, "memory_gbs" => 6})
      assert progress() == [making()]

      assert Server.up(Keyword.put(opts, :memory_gb, 8)) == server_up()
      assert vars(dir) == oci_vars(%{"ocpus" => 1, "memory_gbs" => 8})

      assert progress() == [
               making(),
               {:step,
                "Resizing ehos-trial (memory_in_gbs 6 → 8): the provider stops and starts it, " <>
                  "and its disk and address stay"}
             ]
    end

    # eh-os#285: the plan updates the server for its SSH key or a firewall rule, not its size.
    test "says no resize when the size asked is the server's own, though the plan updates it",
         %{opts: opts} do
      mock_oracle_server()
      mock_ssh("status: done\n", 0)
      opts = with_progress(opts)

      assert Server.up(opts) == server_up()
      _ = drain()

      # The module's default, asked for by name: nothing recorded, nothing resized.
      assert Server.up(Keyword.merge(opts, ocpus: 2, memory_gb: 12)) == server_up()
      assert progress() == [making()]
    end

    test "keeps two installations in one home apart: files, state, OpenTofu's data and names",
         %{opts: opts, tmp_dir: tmp_dir} do
      mock_tofu()
      mock_ssh("status: done\n", 0)

      cloud_init = "cloud-init status --wait >/dev/null; cloud-init status --long"

      for name <- ["trial", "acme"] do
        assert Server.up(Keyword.merge(opts, name: name, ocpus: 1, memory_gb: 6)) ==
                 server_up(name)

        dir = Path.join([tmp_dir, "ehos", name])
        env = tofu_env(dir)

        assert drain() == [
                 {:tofu, tofu_init(dir), env},
                 {:tofu, tofu_plan(dir), env},
                 {:tofu, tofu_show(dir), env},
                 {:tofu, tofu_apply(dir), env},
                 {:tofu, tofu_output(), env},
                 {:ssh, ssh_args(tmp_dir, dir, cloud_init)},
                 {:ssh, ssh_args(tmp_dir, dir, @administrators_read)}
               ]

        assert vars(dir) == oci_vars(%{"name" => name, "ocpus" => 1, "memory_gbs" => 6})
      end
    end

    test "admits SSH from the blocks given instead of this machine's address", %{
      opts: opts,
      dir: dir
    } do
      mock_tofu()
      mock_ssh("status: done\n", 0)
      mock_no_address_asked()
      opts = Keyword.put(opts, :ssh_from, ["192.0.2.0/24"])

      assert Server.up(opts) == server_up()
      assert vars(dir) == oci_vars(%{"ssh_from" => ["192.0.2.0/24"]})
    end

    test "admits a bare --ssh-from address as that address alone", %{opts: opts, dir: dir} do
      mock_tofu()
      mock_ssh("status: done\n", 0)

      assert Server.up(Keyword.put(opts, :ssh_from, ["83.8.86.65", "192.0.2.0/24"])) ==
               server_up()

      assert vars(dir) == oci_vars(%{"ssh_from" => ["83.8.86.65/32", "192.0.2.0/24"]})

      assert Server.up(Keyword.put(opts, :ssh_from, ["83.8.86.65", "83.8.86.65/32"])) ==
               server_up()

      assert vars(dir) == oci_vars(%{"ssh_from" => ["83.8.86.65/32"]})
    end

    # ehos-tools#157: a network that leaves through more than one address.
    test "admits every address this machine was seen to leave from", %{opts: opts, dir: dir} do
      mock_tofu()
      mock_ssh("status: done\n", 0)
      mock_public_addresses({:ok, "77.65.103.58"}, {:ok, "83.8.86.65"})

      assert Server.up(opts) == server_up()
      assert vars(dir) == oci_vars(%{"ssh_from" => ["77.65.103.58/32", "83.8.86.65/32"]})
    end

    test "keeps OpenTofu's state files readable by their owner alone", %{opts: opts, dir: dir} do
      mock_tofu_writing_state(dir)
      mock_ssh("status: done\n", 0)

      assert Server.up(opts) == server_up()
      assert mode(Path.join(dir, "terraform.tfstate")) == 0o600
    end

    test "accepts a first boot that finished with recoverable errors", %{opts: opts} do
      mock_tofu()
      printed = "status: done\nrecoverable_errors:\n  WARNING: deprecated key\n"
      mock_ssh(printed, 2)

      assert Server.up(with_progress(opts)) == server_up()

      assert progress() == [
               making(),
               {:warning, "The first boot of ehos-trial finished with recoverable errors.", nil},
               {:tool_output, "cloud-init status --long", printed}
             ]
    end

    test "reads OpenTofu's JSON past the warnings it prints beside it", %{opts: opts} do
      mock_tofu_warning("Warning: a deprecated argument\n", "\n")
      mock_ssh("status: done\n", 0)

      assert Server.up(opts) == server_up()
    end

    test "refuses a plan that removes or replaces the server, and changes nothing", %{
      opts: opts,
      dir: dir
    } do
      mock_tofu(%{"show" => {plan_json(["delete", "create"]), 0}})
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "server.tfvars.json"), ~s({"availability_domain": 2}))

      assert Server.up(Keyword.put(opts, :availability_domain, 0)) == replacing()
      assert File.read!(Path.join(dir, "server.tfvars.json")) == ~s({"availability_domain": 2})
      assert tofu_runs() == [tofu_init(dir), tofu_plan(dir), tofu_show(dir)]
      refute File.exists?(Path.join(dir, "up.tfplan"))
    end

    test "keeps the old server's host key and kubeconfig when the replacement fails", %{
      opts: opts,
      dir: dir
    } do
      File.mkdir_p!(dir)
      for file <- ~w(known_hosts kubeconfig), do: File.write!(Path.join(dir, file), "old")

      mock_tofu(%{
        "show" => {plan_json(["delete", "create"]), 0},
        "apply" => {"Error: 401-NotAuthenticated\n", 1}
      })

      assert Server.up(Keyword.put(opts, :replace, true)) ==
               {:error, failed("tofu apply", "Error: 401-NotAuthenticated\n")}

      assert File.read!(Path.join(dir, "known_hosts")) == "old"
      assert File.read!(Path.join(dir, "kubeconfig")) == "old"
    end

    test "says when its home cannot be written instead of stopping with a trace", %{
      opts: opts,
      tmp_dir: tmp_dir
    } do
      home = Path.join(tmp_dir, "ehos-home")
      File.mkdir_p!(Path.join(home, "trial"))
      File.write!(Path.join(home, "plugin-cache"), "a file, not a directory")

      assert Server.up(Keyword.put(opts, :home, home)) ==
               {:error, "#{home} cannot be written: not a directory"}
    end

    # eh-os#285: the recorded variables are the server's size until an apply changes it.
    test "keeps the variables when anything stops it before the apply, and says no resize",
         %{opts: opts, dir: dir} do
      File.mkdir_p!(dir)
      path = Path.join(dir, "server.tfvars.json")
      recorded = ~s({"ocpus": 1, "memory_gbs": 6})
      File.write!(path, recorded)
      opts = opts |> Keyword.merge(ocpus: 4, memory_gb: 24) |> with_progress()

      mock_oracle_server()

      # No place recorded yet, so `up` writes installation.json before its first apply, and here
      # cannot, after a plan that would resize the server.
      assert Server.up(read_only_once_making(opts, dir)) ==
               {:error, "#{dir}/installation.json cannot be written: permission denied"}

      File.chmod!(dir, 0o700)
      assert File.read!(path) == recorded
      assert progress() == [making()]

      # A step that raises, as an interrupt would stop it.
      mock_tofu(%{"plan" => fn -> raise "interrupted" end})

      assert_raise RuntimeError, fn -> Server.up(opts) end
      assert File.read!(path) == recorded

      # Variables it could not read are left as they are, never removed.
      File.chmod!(path, 0o200)
      mock_tofu(%{"init" => {"Error: no network\n", 1}})
      assert Server.up(opts) == {:error, failed("tofu init", "Error: no network\n")}
      File.chmod!(path, 0o600)
      assert File.read!(path) == recorded

      # A program that is not there is named alone, without its subcommand.
      mock_tofu(%{"init" => {:error, :not_found}})

      assert Server.up(opts) ==
               {:error,
                "`tofu` is not installed, or not at the version EHOS pins: `ehosctl doctor` " <>
                  "says what is missing (`mix ehos.doctor` in eh-os)"}

      assert File.read!(path) == recorded
    end

    test "keeps the size it had when the plan fails or would replace the server, and says no resize",
         %{opts: opts, dir: dir} do
      File.mkdir_p!(dir)
      recorded = ~s({"ocpus": 1, "memory_gbs": 6})
      File.write!(Path.join(dir, "server.tfvars.json"), recorded)
      opts = with_progress(opts)

      for {answers, refused} <- [
            {%{"plan" => {"Error: Invalid value for variable\n", 1}},
             {:error, failed("tofu plan", "Error: Invalid value for variable\n")}},
            {%{"show" => {plan_json(["delete", "create"]), 0}}, replacing()}
          ] do
        mock_tofu(answers)

        assert Server.up(Keyword.merge(opts, ocpus: 4, memory_gb: 2)) == refused
        assert File.read!(Path.join(dir, "server.tfvars.json")) == recorded
        assert progress() == [making()]
      end
    end

    test "refuses a recorded size no option would take", %{opts: opts, dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "server.tfvars.json"), ~s({"ocpus": {"a": 1}}))

      assert Server.up(opts) ==
               {:error,
                "The size recorded in server.tfvars.json cannot be used: --ocpus is a whole " <>
                  "number from 1, not %{\"a\" => 1}"}
    end

    test "refuses another provider's size before running anything", %{opts: opts} do
      assert Server.up(Keyword.put(opts, :instance_type, "t4g.large")) ==
               {:error,
                "--instance-type does not size a server on oci; give --ocpus and --memory-gb " <>
                  "there (D-84)"}
    end

    # No runner is mocked: a refused value runs nothing, on every provider.
    test "refuses an --ssh-from value the clouds would refuse before running anything, naming it",
         %{opts: opts, dir: dir} do
      for provider <- [
            [],
            [provider: "aws", aws_profile: "ehos"],
            [provider: "gcp", gcp_project: "p"]
          ],
          {value, refused} <- [
            {"192.0.2.1/24",
             "--ssh-from 192.0.2.1/24 has host bits set; give the block as 192.0.2.0/24, or " <>
               "the address alone as 192.0.2.1/32"},
            {"2001:db8::1",
             "--ssh-from 2001:db8::1 is IPv6; the server is reached over IPv4 alone, so give " <>
               "the IPv4 address SSH comes from"},
            {"0.0.0.0/0",
             "--ssh-from 0.0.0.0/0 admits the whole internet; give the addresses SSH comes from"},
            {"128.0.0.0/1",
             "--ssh-from 128.0.0.0/1 is wider than /16, 65,536 addresses; give the block " <>
               "your network leaves through, /16 or narrower"},
            {"host.example",
             "--ssh-from host.example is not an IPv4 address or CIDR block, such as " <>
               "192.0.2.4 or 192.0.2.0/24"},
            {"192.0.2.0/33",
             "--ssh-from 192.0.2.0/33 is not an IPv4 address or CIDR block, such as " <>
               "192.0.2.4 or 192.0.2.0/24"}
          ] do
        opts =
          opts
          |> Keyword.merge(provider)
          |> Keyword.merge(ssh_from: ["198.51.100.0/24", value])

        assert Server.up(opts) == {:error, refused}
        refute File.exists?(Path.join(dir, "server.tfvars.json"))
      end
    end

    test "says where to try again when Oracle has no Ampere capacity", %{opts: opts} do
      mock_tofu(%{"apply" => {"Error: 500-InternalError, Out of host capacity.", 1}})

      assert Server.up(opts) ==
               {:error,
                failed(
                  "tofu apply",
                  "Error: 500-InternalError, Out of host capacity.",
                  "\nOracle has no Ampere capacity there now: run it again later, or, where the " <>
                    "region has more than one availability domain, with another " <>
                    "--availability-domain (from 0)"
                )}
    end

    test "shows the error OpenTofu ends with, not the plan it printed before", %{opts: opts} do
      mock_tofu(%{
        "apply" =>
          {"Plan: 1 to add\n  + metadata = { user_data = \"I2Nsb3Vk\" }\nError: 404-NotAuthorizedOrNotFound\n",
           1}
      })

      assert Server.up(opts) ==
               {:error, failed("tofu apply", "Error: 404-NotAuthorizedOrNotFound\n")}
    end

    test "says to admit this machine's address again when SSH never answers", %{opts: opts} do
      mock_tofu()
      mock_ssh("ssh: connect to host #{@address} port 22: Operation timed out", 255)

      assert Server.up(opts) == never_answered()
    end

    test "refuses to make the server when no address was detected", %{opts: opts} do
      mock_public_address_failing("it answered 503")

      assert Server.up(opts) ==
               {:error,
                "This machine's public address is unknown (checkip.amazonaws.com: it answered " <>
                  "503; api.ipify.org: it answered 503; ipv4.icanhazip.com: it answered 503); " <>
                  "give it with --ssh-from"}
    end

    test "says which addresses are admitted while SSH does not answer, and when it never does",
         %{opts: opts} do
      mock_tofu()
      mock_ssh("ssh: connect to host #{@address} port 22: Operation timed out", 255)
      # Each try and its sleep take 25 seconds by the clock, more than the 10 of the sleep.
      mock_clock_advancing(25)

      assert Server.up(with_progress(opts)) == never_answered()

      # Said when the wait begins and then once for each whole minute, by the clock: 29 tries
      # but the last take 700 seconds.
      waiting = "Waiting for the server to answer SSH. SSH is admitted from 198.51.100.4/32 only."

      assert progress() == [
               making(),
               {:waiting, waiting, 0}
               | for(
                   elapsed <- [75, 125, 200, 250, 300, 375, 425, 500, 550, 600, 675],
                   do: {:waiting, waiting, elapsed * 1000}
                 )
             ]
    end

    # The key was just put on the server, so giving it again would change nothing.
    test "says where to look when the server refuses the key up just put on it", %{
      opts: opts,
      tmp_dir: tmp_dir
    } do
      mock_tofu()
      mock_ssh(denied(), 255)

      refused =
        "The server at #{@address} never answered SSH:\n#{denied()}\nThe server refused the " <>
          "key #{tmp_dir}/id_ed25519 that `up` put on it. "

      assert Server.up(opts) ==
               {:error,
                refused <>
                  "Cloud-init may not have written it: read what the first boot said in the " <>
                  "console history of the instance in Oracle's console"}

      assert Server.up(gcp(opts, [])) ==
               {:error,
                refused <>
                  "An organisation policy that enforces OS Login refuses every key that `up` " <>
                  "puts on a server; else cloud-init did not write it. Read what the first boot " <>
                  "said in the serial port output of the instance in Google Cloud's console"}
    end

    test "says where the log is when the first boot fails", %{opts: opts} do
      mock_tofu()
      mock_ssh("status: error\n", 1)

      assert Server.up(opts) == first_boot_failed("status: error\n")
    end

    # ehos-tools T-30: the apply changed the server, so its secrets are new until an up says so.
    test "reports the secrets as new on the up after one that stopped once the apply changed the server",
         %{opts: opts} do
      mock_tofu()
      mock_ssh("status: error\n", 1)
      assert Server.up(opts) == first_boot_failed("status: error\n")

      mock_tofu(%{"show" => {unchanged_plan(), 0}})
      mock_ssh("status: done\n", 0)
      assert Server.up(opts) == server_up()
      assert Server.up(opts) == server_up("trial", changed?: false)
    end

    test "says how to make the SSH key when it is missing", %{opts: opts, tmp_dir: tmp_dir} do
      assert Server.up(Keyword.put(opts, :ssh_key, Path.join([tmp_dir, "Jane Doe", "none"]))) ==
               {:error,
                "#{tmp_dir}/Jane Doe/none.pub is missing. Make the key with " <>
                  "`ssh-keygen -t ed25519 -f '#{tmp_dir}/Jane Doe/none'`"}
    end

    test "suggests no new key for a recorded one that is not on this machine", %{
      opts: opts,
      dir: dir,
      tmp_dir: tmp_dir
    } do
      elsewhere = Path.join(tmp_dir, "elsewhere")
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, "installation.json"),
        Jason.encode!(%{"provider" => "oci", "ssh_key" => elsewhere})
      )

      assert Server.up(Keyword.delete(opts, :ssh_key)) ==
               {:error,
                "#{elsewhere}.pub is missing. The key #{elsewhere} that `up` recorded is not on " <>
                  "this machine, and a new one would replace the server's: give the private key " <>
                  "that `up` put on the server with `--ssh-key`"}
    end

    # eh-os D-199: the provisioning key stays what `up` recorded, so a workstation without the
    # .pub of the key it logs in with changes nothing on the server.
    test "keeps the provisioning key when this workstation has no public key", %{
      opts: opts,
      dir: dir,
      tmp_dir: tmp_dir
    } do
      stub(EnvMock, :get, fn
        "HOME" -> tmp_dir
        _name -> nil
      end)

      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, "server.tfvars.json"),
        Jason.encode!(oci_vars(%{"ssh_public_key" => "ssh-ed25519 AAAAother operator"}))
      )

      File.write!(Path.join(dir, "installation.json"), ~s({"provider": "oci"}))
      File.write!(Path.join(dir, "terraform.tfstate"), "encrypted")
      default = Path.join([tmp_dir, ".ssh", "ehos_oci"])
      mock_tofu()
      mock_ssh("status: done\n", 0)

      assert Server.up(Keyword.delete(opts, :ssh_key)) ==
               server_up("trial", ssh_key: default)

      assert vars(dir)["ssh_public_key"] == "ssh-ed25519 AAAAother operator"
    end

    test "says how to write the public key when only it is missing", %{
      opts: opts,
      tmp_dir: tmp_dir
    } do
      path = Path.join([tmp_dir, "Jane Doe", "id_ed25519"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "a private key")

      # Written only once `ssh-keygen` succeeded, and with `>|`, which `noclobber` lets replace
      # the empty file an earlier failure left (ehos-tools#571).
      assert Server.up(Keyword.put(opts, :ssh_key, path)) ==
               {:error,
                "#{path}.pub is missing. Write it from the private key with " <>
                  "`pub=$(ssh-keygen -y -f '#{path}') && printf '%s\\n' \"$pub\" >| " <>
                  "'#{path}.pub'`"}
    end

    test "takes a public key whose words are apart by tabs or several spaces", %{
      opts: opts,
      dir: dir,
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "id_ed25519.pub"), "ssh-ed25519\tAAAAkey  operator\n")
      mock_tofu()
      mock_ssh("status: done\n", 0)

      assert Server.up(opts) == server_up()
      assert vars(dir)["ssh_public_key"] == "ssh-ed25519\tAAAAkey  operator"
    end

    test "refuses a public key that is not a type and a key in base64, before running anything",
         %{opts: opts, tmp_dir: tmp_dir} do
      key = Path.join(tmp_dir, "id_ed25519")

      for contents <- ["not-a-key\n", "ssh-ed25519 not&base64 operator\n"] do
        File.write!(key <> ".pub", contents)

        assert Server.up(opts) ==
                 {:error,
                  "#{key}.pub does not hold an SSH public key: a type and a key in base64, " <>
                    "such as `ssh-ed25519 AAAAC3Nza…`"}
      end
    end

    # What `up` records must be what every command reads back (ehos-tools#656).
    test "refuses a key's path that is not printable UTF-8, before running anything", %{
      opts: opts
    } do
      mock_nothing_run()

      for key <- ["/keys/id\u0007key", "/keys/id\u200ekey", "/keys/id" <> <<0xFF>>] do
        for command <- [&Server.up/1, &Server.status/1] do
          assert command.(Keyword.put(opts, :ssh_key, key)) ==
                   {:error,
                    "The path --ssh-key gives holds a control or format character, or is not " <>
                      "UTF-8. Give the path of the private key as a terminal shows it"}
        end
      end
    end

    # `ssh-keygen -y` that failed, its passphrase mistyped, left the file its redirect made, as the
    # command suggested before did.
    test "takes an empty public key for a missing one", %{opts: opts, tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "Jane Doe", "operator_key"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "a private key")
      File.write!(path <> ".pub", " \n")

      assert Server.up(Keyword.put(opts, :ssh_key, path)) ==
               {:error,
                "#{path}.pub is empty. Write it from the private key with " <>
                  "`pub=$(ssh-keygen -y -f '#{path}') && printf '%s\\n' \"$pub\" >| " <>
                  "'#{path}.pub'`"}
    end

    test "names why it cannot read a public key, and suggests nothing over it",
         %{opts: opts, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "operator_key")
      File.write!(path, "a private key")
      File.mkdir_p!(path <> ".pub")

      assert Server.up(Keyword.put(opts, :ssh_key, path)) ==
               {:error, "#{path}.pub cannot be read: illegal operation on a directory"}
    end

    # ehos-tools#656: an operator who keeps a key for each installation names it once, to `up`.
    test "records the key it was given, which a later command uses unless given another", %{
      opts: opts,
      dir: dir,
      tmp_dir: tmp_dir
    } do
      key = Path.join(tmp_dir, "id_ed25519")
      other = Path.join(tmp_dir, "other_key")
      mock_tofu()
      mock_ssh("status: done\n", 0)

      assert Server.up(opts) == server_up()

      assert place(dir) == %{
               "provider" => "oci",
               "oci_profile" => "DEFAULT",
               "region" => "eu-frankfurt-1",
               "tenancy_ocid" => @tenancy,
               "ssh_key" => recorded_key(opts)
             }

      _made = drain()
      without_key = Keyword.delete(opts, :ssh_key)
      assert Server.status(without_key) == status_done()
      assert Server.up(without_key) == server_up()

      assert Server.status(Keyword.put(without_key, :ssh_key, other)) ==
               status_done()

      # `up` reaches the server twice: for the first boot, then for its administrators.
      assert ssh_keys() == [key, key, key, other]
      assert place(dir)["ssh_key"] == recorded_key(opts)
    end

    test "records a key under the operator's home from ~/, and logs in with it from there", %{
      opts: opts,
      dir: dir,
      tmp_dir: tmp_dir
    } do
      stub(EnvMock, :get, fn
        "HOME" -> tmp_dir
        _name -> nil
      end)

      mock_tofu()
      mock_ssh("status: done\n", 0)

      assert Server.up(opts) == server_up()
      assert place(dir)["ssh_key"] == "~/id_ed25519"

      _made = drain()

      assert Server.status(Keyword.delete(opts, :ssh_key)) ==
               status_done()

      assert ssh_keys() == [Path.join(tmp_dir, "id_ed25519")]
    end

    # eh-os D-199: the person who makes the server names themself its first installation
    # administrator, with the key cloud-init put on it.
    test "makes the first installation administrator once the first boot is done", %{
      opts: opts,
      dir: dir
    } do
      test = self()
      key = "ssh-ed25519 AAAAa2V5"
      File.write!(opts[:ssh_key] <> ".pub", "#{key} operator\n")
      mock_tofu(%{"show" => {plan_json(["create"]), 0}})

      stub(CommandRunnerMock, :run, fn
        "ssh", args ->
          command = List.last(args)
          send(test, {:ssh, command})

          cond do
            command =~ "cloud-init" -> {"status: done\n", 0}
            command =~ "kubectl get" -> {administrators("#{key} operator\n"), 0}
            true -> {"", 0}
          end

        "sh", ["-c", _script, input | args] ->
          send(test, {:sh, List.last(args), File.read!(input)})
          {"", 0}
      end)

      assert {:ok, %Report{values: values, warnings: warnings}} =
               Server.up(Keyword.put(opts, :administrator, "ada"))

      %{"administrator" => "ada", "administrator_id" => id} = place(dir)

      assert values == [
               {"Address", @address},
               {"Administrator", "ada (ehos-administrator:ada:#{id})"}
             ]

      # Read again after the change, as the test's server still answers it was before.
      assert warnings == [
               {"No installation administrator has access of their own.",
                "Add each person with `admin add`, with a new key of their own."}
             ]

      assert [_written] =
               for(
                 {:sh, command, input} <- drain(),
                 command =~ "flock",
                 do: assert(input =~ "#{key} ehos-administrator:ada:#{id}\n")
               )
    end

    # The key on cloud-init's line of a server made before can be the one every administrator
    # shares; and an up run again after one that named ada completes what it began.
    test "names the first administrator only on a server it made, and completes an earlier run",
         %{opts: opts, dir: dir} do
      test = self()
      key = "ssh-ed25519 AAAAa2V5"
      File.write!(opts[:ssh_key] <> ".pub", "#{key} operator\n")

      for {prior, keys, expected} <- [
            {@address, "#{key} operator\n", :refused},
            {@address, "#{key} ehos-administrator:ada:1a2b3c4d\n", :completed}
          ] do
        File.rm(Path.join(dir, "previous_address"))
        mock_tofu(%{"show" => {plan_from(prior), 0}})

        stub(CommandRunnerMock, :run, fn
          "ssh", args ->
            command = List.last(args)

            cond do
              command =~ "cloud-init" -> {"status: done\n", 0}
              command =~ "kubectl get" -> {administrators(keys), 0}
              true -> {"", 0}
            end

          "sh", ["-c", _script, input | args] ->
            send(test, {:sh, List.last(args), File.read!(input)})
            {"", 0}
        end)

        result = Server.up(Keyword.put(opts, :administrator, "ada"))
        written = for {:sh, command, _input} <- drain(), do: command

        case expected do
          :refused ->
            assert result ==
                     {:error,
                      "ehosctl named no installation administrator, because ehos-trial was " <>
                        "made before this up, and the key that you log in with can be the key " <>
                        "that every administrator shares. Make a new key, add yourself with it " <>
                        "with `admin add ada --public-key FILE`, then run `tunnel --ssh-key " <>
                        "PRIVATE_KEY` with the private key of that key."}

            assert written == []

          :completed ->
            assert {:ok, %Report{}} = result
            assert written == ["sudo k3s kubectl create --request-timeout=30s -f -"]
            assert place(dir)["administrator_id"] == "1a2b3c4d"
        end
      end
    end

    # The mark that this workstation made the server outlives an `up` that stopped after its apply;
    # an `up --administrator` run after one that named the person writes nothing.
    test "names the first administrator after an up that stopped, and writes nothing once named",
         %{opts: opts, dir: dir} do
      test = self()
      key = "ssh-ed25519 AAAAa2V5"
      File.write!(opts[:ssh_key] <> ".pub", "#{key} operator\n")
      named = "#{key} ehos-administrator:ada:1a2b3c4d\n"

      # The first run makes the server, and stops at its first boot.
      mock_tofu(%{"show" => {plan_json(["create"]), 0}})
      mock_ssh("Connection refused", 1)
      assert {:error, _stopped} = Server.up(Keyword.put(opts, :administrator, "ada"))
      assert place(dir)["administrator_pending"] == true

      for {keys, bindings, written} <- [
            {"#{key} operator\n", [], 3},
            {named, [Administrators.binding("ada", "1a2b3c4d")], 0}
          ] do
        File.rm(Path.join(dir, "previous_address"))
        mock_tofu(%{"show" => {plan_from(@address), 0}})

        stub(CommandRunnerMock, :run, fn
          "ssh", args ->
            command = List.last(args)

            cond do
              command =~ "cloud-init" -> {"status: done\n", 0}
              command =~ "kubectl get" -> {administrators(keys, bindings), 0}
              true -> {"", 0}
            end

          "sh", ["-c", _script, input | args] ->
            send(test, {:sh, List.last(args), File.read!(input)})
            {"", 0}
        end)

        assert {:ok, %Report{}} = Server.up(Keyword.put(opts, :administrator, "ada"))
        assert length(for({:sh, _command, _input} <- drain(), do: :written)) == written
        assert place(dir)["administrator"] == "ada"
        refute Map.has_key?(place(dir), "administrator_pending")

        File.write!(
          Path.join(dir, "installation.json"),
          Jason.encode!(Map.put(place(dir), "administrator_pending", true))
        )
      end
    end

    # ehosctl gives the user name on the workstation: the person who makes the server is its first
    # installation administrator without naming themself, and `--administrator` still names them.
    test "names the first administrator from the user name on a server it makes, unless given one",
         %{opts: opts, dir: dir} do
      test = self()
      key = "ssh-ed25519 AAAAa2V5"
      File.write!(opts[:ssh_key] <> ".pub", "#{key} operator\n")

      for {given, name} <- [{[], "ada-lovelace"}, {[administrator: "ada"], "ada"}] do
        File.rm_rf!(dir)
        mock_tofu(%{"show" => {plan_json(["create"]), 0}})

        stub(CommandRunnerMock, :run, fn
          "ssh", args ->
            command = List.last(args)

            cond do
              command =~ "cloud-init" -> {"status: done\n", 0}
              command =~ "kubectl get" -> {administrators("#{key} operator\n"), 0}
              true -> {"", 0}
            end

          "sh", ["-c", _script, input | args] ->
            send(test, {:sh, List.last(args), File.read!(input)})
            {"", 0}
        end)

        opts = opts |> Keyword.put(:default_administrator, "Ada.Lovelace") |> Keyword.merge(given)
        assert {:ok, %Report{values: values}} = Server.up(opts)
        %{"administrator" => ^name, "administrator_id" => id} = place(dir)

        assert values == [
                 {"Address", @address},
                 {"Administrator", "#{name} (ehos-administrator:#{name}:#{id})"}
               ]

        assert [_written] =
                 for(
                   {:sh, command, input} <- drain(),
                   command =~ "flock",
                   do: assert(input =~ "#{key} ehos-administrator:#{name}:#{id}\n")
                 )
      end
    end

    # The key on cloud-init's line of a server made before can be the one every administrator
    # shares, and a server made here may have a person already: a name nobody gave names nobody
    # there, and refuses nothing.
    test "names nobody by default on a server made before, or one with an administrator already",
         %{opts: opts, dir: dir} do
      test = self()
      key = "ssh-ed25519 AAAAa2V5"
      File.write!(opts[:ssh_key] <> ".pub", "#{key} operator\n")
      bob = "ssh-ed25519 AAAAb3Rozg== ehos-administrator:bob:5e6f7a8b\n"
      # A server an `up` made before, on this workstation or another.
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "terraform.tfstate"), "encrypted")
      File.write!(Path.join(dir, "installation.json"), ~s({"provider": "oci"}))

      File.write!(
        Path.join(dir, "server.tfvars.json"),
        Jason.encode!(Map.put(oci_vars(), "ssh_public_key", "#{key} operator"))
      )

      for {plan, keys, user} <- [
            {plan_from(@address), "#{key} operator\n", "ada"},
            {plan_from(@address), "#{key} operator\n", "1001"},
            {plan_json(["create"]), "#{key} operator\n" <> bob, "ada"}
          ] do
        File.rm(Path.join(dir, "previous_address"))
        mock_tofu(%{"show" => {plan, 0}})

        stub(CommandRunnerMock, :run, fn
          "ssh", args ->
            command = List.last(args)

            cond do
              command =~ "cloud-init" -> {"status: done\n", 0}
              command =~ "kubectl get" -> {administrators(keys), 0}
              true -> {"", 0}
            end

          "sh", ["-c", _script, input | args] ->
            send(test, {:sh, List.last(args), File.read!(input)})
            {"", 0}
        end)

        assert {:ok, %Report{values: [{"Address", @address}]}} =
                 Server.up(Keyword.put(opts, :default_administrator, user))

        assert for({:sh, command, _input} <- drain(), do: command) == []
        refute Map.has_key?(place(dir), "administrator")
      end
    end

    # eh-os D-199: the mark of a server made here travels with a copied folder; only the person
    # whose name it holds is named by default, and a server eh-os's tasks made names nobody.
    test "names by default only the person whose up made the server", %{opts: opts, dir: dir} do
      test = self()
      key = "ssh-ed25519 AAAAa2V5"
      File.write!(opts[:ssh_key] <> ".pub", "#{key} operator\n")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "terraform.tfstate"), "encrypted")

      File.write!(
        Path.join(dir, "server.tfvars.json"),
        Jason.encode!(Map.put(oci_vars(), "ssh_public_key", "#{key} operator"))
      )

      # A user name that makes no name refuses nothing where no default would be used.
      for {mark, user, named} <- [
            {"alice", "bob", nil},
            {true, "bob", nil},
            {"alice", "1001", nil},
            {true, "1001", nil},
            {"ada", "Ada", "ada"}
          ] do
        File.write!(
          Path.join(dir, "installation.json"),
          Jason.encode!(%{"provider" => "oci", "administrator_pending" => mark})
        )

        File.rm(Path.join(dir, "previous_address"))
        mock_tofu(%{"show" => {plan_from(@address), 0}})

        stub(CommandRunnerMock, :run, fn
          "ssh", args ->
            command = List.last(args)

            cond do
              command =~ "cloud-init" -> {"status: done\n", 0}
              command =~ "kubectl get" -> {administrators("#{key} operator\n"), 0}
              true -> {"", 0}
            end

          "sh", ["-c", _script, input | args] ->
            send(test, {:sh, List.last(args), File.read!(input)})
            {"", 0}
        end)

        assert {:ok, %Report{}} = Server.up(Keyword.put(opts, :default_administrator, user))
        written = for {:sh, command, _input} <- drain(), do: command
        assert place(dir)["administrator"] == named

        if named,
          do: assert(written != []),
          else: assert({written, place(dir)["administrator_pending"]} == {[], mark})
      end
    end

    # The mark is honoured only for its own name: another person's `--administrator` over a copied
    # folder would give their name to the key on cloud-init's line, which can be the shared one.
    test "refuses --administrator over the mark of another person's up, and completes its own", %{
      opts: opts,
      dir: dir
    } do
      test = self()
      key = "ssh-ed25519 AAAAa2V5"
      File.write!(opts[:ssh_key] <> ".pub", "#{key} operator\n")

      # Emil's up names ada, and stops at the first boot: the mark is emil's own name.
      mock_tofu(%{"show" => {plan_json(["create"]), 0}})
      mock_ssh("Connection refused", 1)
      given = Keyword.merge(opts, administrator: "ada", default_administrator: "Emil")
      assert {:error, _stopped} = Server.up(given)
      assert place(dir)["administrator_pending"] == "emil"

      for {run, expected} <- [
            {[default_administrator: "bob", administrator: "bob"], :refused},
            {[default_administrator: "Emil"], "emil"}
          ] do
        File.rm(Path.join(dir, "previous_address"))
        mock_tofu(%{"show" => {plan_from(@address), 0}})

        stub(CommandRunnerMock, :run, fn
          "ssh", args ->
            command = List.last(args)

            cond do
              command =~ "cloud-init" -> {"status: done\n", 0}
              command =~ "kubectl get" -> {administrators("#{key} operator\n"), 0}
              true -> {"", 0}
            end

          "sh", ["-c", _script, input | args] ->
            send(test, {:sh, List.last(args), File.read!(input)})
            {"", 0}
        end)

        result = Server.up(Keyword.merge(opts, run))
        written = for {:sh, command, _input} <- drain(), do: command

        case expected do
          :refused ->
            assert {:error, "ehosctl named no installation administrator, because" <> _} = result
            assert written == []

          name ->
            assert {:ok, %Report{}} = result
            assert place(dir)["administrator"] == name
        end
      end
    end

    # After `down`, the state and the variables stay: only the apply shows that `up` made the
    # server again.
    test "refuses a user name that makes no name once it made the server again", %{
      opts: opts,
      dir: dir
    } do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "terraform.tfstate"), "encrypted")
      File.write!(Path.join(dir, "installation.json"), ~s({"provider": "oci"}))
      File.write!(Path.join(dir, "server.tfvars.json"), Jason.encode!(oci_vars()))
      mock_tofu(%{"show" => {plan_json(["create"]), 0}})
      mock_ssh("status: done\n", 0)

      assert Server.up(Keyword.put(opts, :default_administrator, "1001")) ==
               {:error,
                "ehosctl cannot make the name of an installation administrator from your user " <>
                  "name on this computer. Give your name with `mix ehos.server up " <>
                  "--administrator NAME`. A name has 1 to 31 lowercase letters, digits and " <>
                  "hyphens, starts with a letter, and is not shared"}

      assert Enum.any?(tofu_runs(), &("apply" in &1))
      assert place(dir)["administrator_pending"] == true
    end

    test "refuses a user name that makes no name of an administrator before anything runs", %{
      opts: opts
    } do
      mock_nothing_run()

      for user <- ["1001", "", "shared"] do
        assert Server.up(Keyword.put(opts, :default_administrator, user)) ==
                 {:error,
                  "ehosctl cannot make the name of an installation administrator from your user " <>
                    "name on this computer. Give your name with `mix ehos.server up " <>
                    "--administrator NAME`. A name has 1 to 31 lowercase letters, digits and " <>
                    "hyphens, starts with a letter, and is not shared"}
      end

      assert {:error, "\"shared\" cannot name" <> _} =
               Server.up(
                 opts
                 |> Keyword.put(:default_administrator, "")
                 |> Keyword.put(:administrator, "shared")
               )
    end

    # A server removed by hand is made again by a plan that only creates it.
    test "refuses to make the server again by hand's removal with another key, or with no .pub",
         %{opts: opts, dir: dir, tmp_dir: tmp_dir} do
      made_before_keys_were_recorded(opts, dir, tmp_dir)
      other = Path.join(tmp_dir, "other_key")
      File.write!(other <> ".pub", "ssh-ed25519 AAAAother operator\n")
      mock_tofu(%{"show" => {plan_json(["create"]), 0}})

      # A plan that only makes the server again needs no --replace.
      assert Server.up(Keyword.put(opts, :ssh_key, other)) ==
               {:error,
                "ehosctl changed nothing. The plan makes ehos-trial, and the new server would " <>
                  "take the provisioning key, not #{other}.pub, which you log in with. Give your " <>
                  "own key to the new server with `mix ehos.server up --provisioning-key " <>
                  "#{Shell.word(other <> ".pub")}`"}

      File.rm!(other <> ".pub")

      assert Server.up(Keyword.put(opts, :ssh_key, other)) ==
               {:error,
                "ehosctl changed nothing. The plan makes ehos-trial, and ehosctl cannot read " <>
                  "#{other}.pub to check that the new server takes the key that you log in with. " <>
                  "Write it from the private key with `pub=$(ssh-keygen -y -f #{Shell.word(other)}) " <>
                  "&& printf '%s\\n' \"$pub\" >| #{Shell.word(other <> ".pub")}`, then run this " <>
                  "command again"}

      refute Enum.any?(tofu_runs(), &("apply" in &1))
    end

    test "refuses a name --administrator cannot take before anything runs", %{opts: opts} do
      mock_nothing_run()

      assert Server.up(Keyword.put(opts, :administrator, "shared")) ==
               {:error,
                "\"shared\" cannot name an installation administrator. A name has 1 to 31 " <>
                  "lowercase letters, digits and hyphens, starts with a letter, and is not shared"}
    end

    # eh-os D-199: `--ssh-key`, or the default key, chooses only the key this workstation logs in
    # with; the server keeps the provisioning key, and only `--provisioning-key` replaces it.
    test "keeps the provisioning key whatever key this workstation logs in with", %{
      opts: opts,
      dir: dir,
      tmp_dir: tmp_dir
    } do
      stub(EnvMock, :get, fn
        "HOME" -> tmp_dir
        _name -> nil
      end)

      default = made_before_keys_were_recorded(opts, dir, tmp_dir)

      assert Server.up(Keyword.delete(opts, :ssh_key)) == server_up("trial", ssh_key: default)
      assert vars(dir)["ssh_public_key"] == "ssh-ed25519 AAAAkey operator"
      assert place(dir)["ssh_key"] == "~/.ssh/ehos_oci"
    end

    # A key the server refuses never replaces, as the default, the one it takes.
    test "records another --ssh-key of a server made only once SSH takes it", %{
      opts: opts,
      dir: dir,
      tmp_dir: tmp_dir
    } do
      made_before_keys_were_recorded(opts, dir, tmp_dir)
      recorded = place(dir)["ssh_key"]
      other = Path.join(tmp_dir, "other_key")
      File.write!(other <> ".pub", "ssh-ed25519 AAAAother operator\n")
      mock_tofu()
      mock_ssh("ubuntu@#{@address}: Permission denied (publickey).", 255)

      assert {:error, _refused} = Server.up(Keyword.put(opts, :ssh_key, other))
      assert place(dir)["ssh_key"] == recorded

      mock_ssh("status: done\n", 0)
      assert {:ok, _report} = Server.up(Keyword.put(opts, :ssh_key, other))
      assert place(dir)["ssh_key"] == recorded_key(ssh_key: other)
    end

    # The first boot's SSH can go through a control master opened with the key recorded before.
    test "records another --ssh-key only once a login of its own with it succeeds", %{
      opts: opts,
      dir: dir,
      tmp_dir: tmp_dir
    } do
      made_before_keys_were_recorded(opts, dir, tmp_dir)
      recorded = recorded_key(opts)

      File.write!(
        Path.join(dir, "installation.json"),
        Jason.encode!(Map.put(place(dir), "ssh_key", recorded))
      )

      other = Path.join(tmp_dir, "other_key")
      File.write!(other <> ".pub", "ssh-ed25519 AAAAother operator\n")
      mock_tofu()

      stub(CommandRunnerMock, :run, fn "ssh", args ->
        if "ControlPath=none" in args,
          do: {"ubuntu@#{@address}: Permission denied (publickey).", 255},
          else: {"status: done\n", 0}
      end)

      assert {:error, %EhosPlatform.Failure{said: said}} =
               Server.up(Keyword.put(opts, :ssh_key, other))

      assert said =~ "The server is up, but it refused #{other} on a new login"
      assert place(dir)["ssh_key"] == recorded

      # A login that fails for another reason, as a timeout, is not called a refusal.
      stub(CommandRunnerMock, :run, fn "ssh", args ->
        if "ControlPath=none" in args,
          do: {"ssh: connect to host #{@address} port 22: Connection timed out", 255},
          else: {"status: done\n", 0}
      end)

      assert {:error, %EhosPlatform.Failure{said: said}} =
               Server.up(Keyword.put(opts, :ssh_key, other))

      assert said =~ "could not log in to it again with #{other}"
      assert place(dir)["ssh_key"] == recorded

      # Taken on a login of its own, the key is recorded; the same key again needs no such login.
      test = self()

      stub(CommandRunnerMock, :run, fn "ssh", args ->
        send(test, {:fresh, "ControlPath=none" in args})
        {"status: done\n", 0}
      end)

      assert {:ok, _report} = Server.up(Keyword.put(opts, :ssh_key, other))
      assert true in for({:fresh, fresh?} <- drain(), do: fresh?)
      assert place(dir)["ssh_key"] == recorded_key(ssh_key: other)

      assert {:ok, _report} = Server.up(Keyword.put(opts, :ssh_key, other))
      refute true in for({:fresh, fresh?} <- drain(), do: fresh?)
    end

    # An installation that records no key logged in with the default key before.
    test "makes a new login for another key on an installation that recorded none", %{
      opts: opts,
      dir: dir,
      tmp_dir: tmp_dir
    } do
      made_before_keys_were_recorded(opts, dir, tmp_dir)
      other = Path.join(tmp_dir, "other_key")
      File.write!(other <> ".pub", "ssh-ed25519 AAAAother operator\n")
      mock_tofu()

      stub(CommandRunnerMock, :run, fn "ssh", args ->
        if "ControlPath=none" in args,
          do: {"ubuntu@#{@address}: Permission denied (publickey).", 255},
          else: {"status: done\n", 0}
      end)

      assert {:error, %EhosPlatform.Failure{said: said}} =
               Server.up(Keyword.put(opts, :ssh_key, other))

      assert said =~ "it refused #{other} on a new login"
      refute Map.has_key?(place(dir), "ssh_key")
    end

    # A replacement records its key before the apply, so the key is the recorded one after it.
    test "makes no new login for the key of a replacement, recorded before its apply", %{
      opts: opts,
      dir: dir,
      tmp_dir: tmp_dir
    } do
      made_before_keys_were_recorded(opts, dir, tmp_dir)

      File.write!(
        Path.join(dir, "installation.json"),
        Jason.encode!(Map.put(place(dir), "ssh_key", recorded_key(opts)))
      )

      other = Path.join(tmp_dir, "other_key")
      File.write!(other <> ".pub", "ssh-ed25519 AAAAother operator\n")
      mock_tofu(%{"show" => {plan_json(["delete", "create"]), 0}})

      stub(CommandRunnerMock, :run, fn "ssh", args ->
        if "ControlPath=none" in args,
          do: {"ssh: connect to host #{@address} port 22: Connection timed out", 255},
          else: {"status: done\n", 0}
      end)

      opts =
        Keyword.merge(opts, ssh_key: other, provisioning_key: other <> ".pub", replace: true)

      assert {:ok, _report} = Server.up(opts)
      assert place(dir)["ssh_key"] == recorded_key(ssh_key: other)
    end

    # The administrators of a server made again are none of the old one's; a failed apply that
    # would make one leaves no mark that it did.
    test "forgets the administrator of a server made again, and marks no server a failed apply made",
         %{opts: opts, dir: dir, tmp_dir: tmp_dir} do
      made_before_keys_were_recorded(opts, dir, tmp_dir)

      File.write!(
        Path.join(dir, "installation.json"),
        Jason.encode!(
          Map.merge(place(dir), %{"administrator" => "ada", "administrator_id" => "1a2b3c4d"})
        )
      )

      # A replacement that fails can leave the old server: no mark, and its administrator stays.
      replacing = %{"show" => {plan_json(["delete", "create"]), 0}}
      mock_tofu(Map.put(replacing, "apply", {"Error: quota", 1}))
      assert {:error, _failed} = Server.up(Keyword.put(opts, :replace, true))
      refute Map.has_key?(place(dir), "administrator_pending")
      assert place(dir)["administrator"] == "ada"

      # The retry only makes the server; its apply succeeds, and the old administrator goes.
      mock_tofu(%{"show" => {plan_json(["create"]), 0}})
      mock_ssh("status: done\n", 0)
      assert {:ok, _report} = Server.up(opts)
      refute Map.has_key?(place(dir), "administrator")
      refute Map.has_key?(place(dir), "administrator_id")
      assert place(dir)["administrator_pending"] == true
    end

    # A first make that fails after it made the server still lets this workstation name itself.
    test "marks a server it makes where none is before the apply, which can fail part way",
         %{opts: opts, dir: dir} do
      mock_tofu(%{"show" => {plan_json(["create"]), 0}, "apply" => {"Error: quota", 1}})
      assert {:error, _failed} = Server.up(opts)
      assert place(dir)["administrator_pending"] == true
    end

    # The new server takes the provisioning key, so the key that logs in to it is the one to keep.
    test "records the key of a replacement before its apply, though its first boot fails",
         %{opts: opts, dir: dir, tmp_dir: tmp_dir} do
      made_before_keys_were_recorded(opts, dir, tmp_dir)
      other = Path.join(tmp_dir, "other_key")
      File.write!(other <> ".pub", "ssh-ed25519 AAAAother operator\n")
      mock_tofu(%{"show" => {plan_json(["delete", "create"]), 0}})
      mock_ssh("Connection refused", 1)

      opts =
        Keyword.merge(opts, ssh_key: other, provisioning_key: other <> ".pub", replace: true)

      assert {:error, _first_boot} = Server.up(opts)
      assert place(dir)["ssh_key"] == recorded_key(ssh_key: other)
    end

    # eh-os D-199: the new server takes the provisioning key, which can be a person's who left.
    test "refuses to make the server again with a provisioning key that is not the one it logs in with",
         %{opts: opts, dir: dir, tmp_dir: tmp_dir} do
      made_before_keys_were_recorded(opts, dir, tmp_dir)
      other = Path.join(tmp_dir, "other_key")
      File.write!(other <> ".pub", "ssh-ed25519 AAAAother operator\n")
      mock_tofu(%{"show" => {plan_json(["delete", "create"]), 0}})

      opts = opts |> Keyword.put(:ssh_key, other) |> Keyword.put(:replace, true)

      assert Server.up(opts) ==
               {:error,
                "ehosctl changed nothing. The plan makes ehos-trial, and the new server would " <>
                  "take the provisioning key, not #{other}.pub, which you log in with. Give your " <>
                  "own key to the new server with `mix ehos.server up --replace " <>
                  "--provisioning-key #{other}.pub`"}

      refute Enum.any?(tofu_runs(), &("apply" in &1))
      assert vars(dir)["ssh_public_key"] == "ssh-ed25519 AAAAkey operator"

      assert {:ok, _report} = Server.up(Keyword.put(opts, :provisioning_key, other <> ".pub"))
      assert vars(dir)["ssh_public_key"] == "ssh-ed25519 AAAAother operator"
    end

    test "replaces the provisioning key with the one --provisioning-key gives", %{
      opts: opts,
      dir: dir,
      tmp_dir: tmp_dir
    } do
      made_before_keys_were_recorded(opts, dir, tmp_dir)
      other = Path.join(tmp_dir, "other_key.pub")
      File.write!(other, "ssh-ed25519 AAAAother operator\n")

      assert Server.up(Keyword.put(opts, :provisioning_key, other)) == server_up()
      assert vars(dir)["ssh_public_key"] == "ssh-ed25519 AAAAother operator"

      File.write!(other, "not-a-key\n")

      assert Server.up(Keyword.put(opts, :provisioning_key, other)) ==
               {:error,
                "#{other} does not hold an SSH public key: a type and a key in base64, such as " <>
                  "`ssh-ed25519 AAAAC3Nza…`"}
    end

    test "puts the default key on a server not made yet", %{
      opts: opts,
      dir: dir,
      tmp_dir: tmp_dir
    } do
      stub(EnvMock, :get, fn
        "HOME" -> tmp_dir
        _name -> nil
      end)

      made_before_keys_were_recorded(opts, dir, tmp_dir)
      default = Path.join(tmp_dir, ".ssh/ehos_oci")
      File.rm!(Path.join(dir, "terraform.tfstate"))

      assert Server.up(Keyword.delete(opts, :ssh_key)) == server_up("trial", ssh_key: default)
      assert vars(dir)["ssh_public_key"] == "ssh-ed25519 AAAAdefault operator"
    end

    # ehos-tools#1028: installation.json was written through a fixed name beside it, so a link
    # there was written through, and at the umask's mode until its chmod.
    test "records the place readable by its owner alone, never through a link beside it",
         %{opts: opts, dir: dir, tmp_dir: tmp_dir} do
      elsewhere = Path.join(tmp_dir, "elsewhere")
      File.write!(elsewhere, "untouched")
      File.mkdir_p!(dir)
      File.ln_s!(elsewhere, Path.join(dir, "installation.json.partial"))
      mock_tofu()
      mock_ssh("status: done\n", 0)

      assert Server.up(opts) == server_up()

      assert File.read!(elsewhere) == "untouched"
      assert mode(Path.join(dir, "installation.json")) == 0o600
    end

    # Keeping the variables is the last step before the apply: what stops `up` before it leaves
    # them as they were.
    test "keeps the variables as they were when the key cannot be recorded", %{
      opts: opts,
      dir: dir,
      tmp_dir: tmp_dir
    } do
      other = Path.join(tmp_dir, "other_key")
      File.write!(other <> ".pub", "ssh-ed25519 AAAAother operator\n")
      mock_tofu()
      mock_ssh("status: done\n", 0)
      assert Server.up(opts) == server_up()

      opts = opts |> Keyword.put(:ssh_key, other) |> read_only_once_making(dir)

      assert Server.up(opts) ==
               {:error, "#{dir}/installation.json cannot be written: permission denied"}

      File.chmod!(dir, 0o700)

      assert vars(dir)["ssh_public_key"] == "ssh-ed25519 AAAAkey operator"
    end

    test "records the key another up is given in place of the one before", %{
      opts: opts,
      dir: dir,
      tmp_dir: tmp_dir
    } do
      other = Path.join(tmp_dir, "other_key")
      File.write!(other <> ".pub", "ssh-ed25519 AAAAother operator\n")
      mock_tofu()
      mock_ssh("status: done\n", 0)

      assert Server.up(opts) == server_up()
      assert Server.up(Keyword.put(opts, :ssh_key, other)) == server_up("trial", ssh_key: other)

      assert place(dir)["ssh_key"] == recorded_key(ssh_key: other)
      assert vars(dir)["ssh_public_key"] == "ssh-ed25519 AAAAother operator"
    end
  end

  # D-83: a server on AWS, GCP or OVHcloud as on Oracle.
  describe "up/1 on AWS, GCP and OVHcloud" do
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
      # The account or project is the module's to say, after the apply: the variables leave it
      # empty, and it is read once more than the address, to be recorded.
      for {provider, extra, outputs, written, recorded} <- [
            {"aws", [aws_profile: "ehos"], 2,
             %{"region" => "eu-central-1", "aws_profile" => "ehos", "aws_account_id" => ""},
             %{"region" => "eu-central-1", "aws_profile" => "ehos", "aws_account_id" => @account}},
            {"gcp", [gcp_project: "acme-ehos"], 1,
             %{"region" => "europe-west3", "project" => "acme-ehos"},
             %{"region" => "europe-west3", "project" => "acme-ehos"}},
            {"ovh", [], 2, %{"region" => "GRA11", "os_cloud" => "ovh", "project_id" => ""},
             %{"region" => "GRA11", "os_cloud" => "ovh", "project_id" => @project}}
          ] do
        File.rm_rf!(dir)
        mock_tofu()
        opts = opts |> Keyword.merge(extra) |> Keyword.merge(provider: provider)

        assert Server.up(opts) == server_up()

        assert tofu_runs() == [
                 tofu_init(dir, provider),
                 tofu_plan(dir, provider),
                 tofu_show(dir, provider),
                 tofu_apply(dir, provider)
                 | List.duplicate(tofu_output(provider), outputs)
               ]

        assert vars(dir) ==
                 Map.merge(written, %{
                   "name" => "trial",
                   "availability_domain" => 0,
                   "ssh_public_key" => "ssh-ed25519 AAAAkey operator",
                   "ssh_from" => ["198.51.100.4/32"]
                 })

        assert place(dir) ==
                 Map.merge(recorded, %{"provider" => provider, "ssh_key" => recorded_key(opts)})
      end
    end

    test "replaces the provider's own instance when asked to, on AWS without a lift", %{
      opts: opts,
      dir: dir
    } do
      mock_tofu(%{"show" => {plan_json(["delete", "create"], "aws_instance.server"), 0}})

      assert Server.up(Keyword.merge(opts, provider: "aws", replace: true)) == server_up()

      assert tofu_runs() == [
               tofu_init(dir, "aws"),
               tofu_plan(dir, "aws", ["-replace=aws_instance.server"]),
               tofu_show(dir, "aws"),
               tofu_apply(dir, "aws"),
               tofu_output("aws"),
               tofu_output("aws")
             ]
    end

    # ehos-tools#430: Compute Engine refuses deleting a protected instance, so the plan that
    # replaces it is made again once the protection is lifted, by an apply on the server alone.
    test "on GCP, lifts the deletion protection before it replaces the server", %{
      opts: opts,
      tmp_dir: tmp_dir
    } do
      mock_tofu(%{
        "show" => {plan_json(["delete", "create"], @gcp_instance), 0},
        lift: {lift_json(), 0}
      })

      assert Server.up(gcp(opts, replace: true)) == server_up("gcpx")

      dir = Path.join([tmp_dir, "ehos", "gcpx"])
      env = tofu_env(dir)
      lifting = tofu_env(dir, [], "false")
      replacing = ["-replace=#{@gcp_instance}"]

      assert drain() == [
               {:tofu, tofu_init(dir, "gcp"), env},
               {:tofu, tofu_plan(dir, "gcp", replacing), env},
               {:tofu, tofu_show(dir, "gcp"), env},
               {:tofu, tofu_lift(dir), lifting},
               {:tofu, tofu_show(dir, "gcp", "unprotect.tfplan"), env},
               {:tofu, tofu_apply(dir, "gcp", "unprotect.tfplan"), lifting},
               {:tofu, tofu_init(dir, "gcp"), env},
               {:tofu, tofu_plan(dir, "gcp", replacing), env},
               {:tofu, tofu_show(dir, "gcp"), env},
               {:tofu, tofu_apply(dir, "gcp"), env},
               {:tofu, tofu_output("gcp"), env}
             ]
    end

    test "lifts no protection for a plan that keeps the server, and takes the operator's " <>
           "TF_VAR_deletion_protection out of OpenTofu's environment",
         %{opts: opts, tmp_dir: tmp_dir} do
      mock_tofu()

      assert Server.up(gcp(opts, replace: true)) == server_up("gcpx")

      dir = Path.join([tmp_dir, "ehos", "gcpx"])
      env = tofu_env(dir)

      assert drain() == [
               {:tofu, tofu_init(dir, "gcp"), env},
               {:tofu, tofu_plan(dir, "gcp", ["-replace=#{@gcp_instance}"]), env},
               {:tofu, tofu_show(dir, "gcp"), env},
               {:tofu, tofu_apply(dir, "gcp"), env},
               {:tofu, tofu_output("gcp"), env}
             ]
    end

    # D-84: from the plan's own values.
    test "says a server is resized from its type before and after in the plan", %{
      opts: opts
    } do
      opts = with_progress(opts)

      for {provider, instance, attribute} <- [
            {"aws", "aws_instance.server", "instance_type"},
            {"gcp", "google_compute_instance.server", "machine_type"},
            {"ovh", "openstack_compute_instance_v2.server", "flavor_name"}
          ] do
        resized =
          plan_json(["update"], instance, %{attribute => "small-1"}, %{attribute => "large-2"})

        mock_tofu(%{"show" => {resized, 0}})
        name = provider <> "x"

        assert Server.up(
                 Keyword.merge(opts,
                   provider: provider,
                   gcp_project: "p",
                   name: name,
                   instance_type: "large-2"
                 )
               ) == server_up(name)

        assert progress() == [
                 making(name),
                 {:step,
                  "Resizing ehos-#{name} (#{attribute} small-1 → large-2): the provider stops " <>
                    "and starts it, and its disk and address stay"}
               ]
      end
    end

    test "keeps the provider, project and region it used before", %{opts: opts, dir: dir} do
      mock_tofu()

      first = Keyword.merge(opts, provider: "gcp", gcp_project: "acme", region: "europe-west4")
      assert Server.up(first) == server_up()
      assert Server.up(opts) == server_up()

      assert vars(dir) == %{
               "name" => "trial",
               "project" => "acme",
               "region" => "europe-west4",
               "availability_domain" => 0,
               "ssh_public_key" => "ssh-ed25519 AAAAkey operator",
               "ssh_from" => ["198.51.100.4/32"]
             }
    end

    # D-126: only a server not made yet needs its cloud named.
    test "keeps an installation on Oracle without :provider once it is made", %{
      opts: opts,
      dir: dir
    } do
      mock_tofu()
      assert Server.up(Keyword.put(opts, :provider, "oci")) == server_up()

      assert place(dir) == %{
               "provider" => "oci",
               "oci_profile" => "DEFAULT",
               "region" => "eu-frankfurt-1",
               "tenancy_ocid" => @tenancy,
               "ssh_key" => recorded_key(opts)
             }

      assert Server.provider_named(opts) == :ok
      assert Server.up(opts) == server_up()
      assert Server.status(opts) == status_done()
    end

    # Made before D-83, when Oracle was the one provider: its variables and a state, no record.
    test "reads an installation made before the provider was recorded as Oracle's", %{
      opts: opts,
      dir: dir
    } do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "server.tfvars.json"), ~s({"tenancy_ocid": "t", "region": "r"}))
      File.write!(Path.join(dir, "terraform.tfstate"), "encrypted")
      assert Server.provider_named(opts) == :ok

      assert Server.up(Keyword.merge(opts, provider: "aws")) == moved(dir, "oci", "aws")
    end

    test "records the key on an Oracle installation made before the provider was recorded", %{
      opts: opts,
      dir: dir
    } do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "server.tfvars.json"), Jason.encode!(oci_vars()))
      File.write!(Path.join(dir, "terraform.tfstate"), "encrypted")
      mock_tofu()
      mock_ssh("status: done\n", 0)

      assert Server.up(opts) == server_up()

      assert place(dir) == %{
               "provider" => "oci",
               "oci_profile" => "DEFAULT",
               "region" => "eu-frankfurt-1",
               "tenancy_ocid" => @tenancy,
               "ssh_key" => recorded_key(opts)
             }

      assert Server.made?(opts)
      assert Server.provider_named(opts) == :ok
    end

    test "pins the account it made the server in, and refuses another account or region", %{
      opts: opts,
      dir: dir
    } do
      mock_tofu()
      assert Server.up(Keyword.merge(opts, provider: "aws", aws_profile: "acme")) == server_up()

      assert place(dir) == %{
               "provider" => "aws",
               "aws_account_id" => @account,
               "aws_profile" => "acme",
               "region" => "eu-central-1",
               "ssh_key" => recorded_key(opts)
             }

      # The next run pins the provider to that account, whatever the profile names.
      assert Server.up(Keyword.put(opts, :aws_profile, "renamed")) == server_up()
      assert vars(dir) == aws_vars(%{"aws_profile" => "renamed"})

      before = File.read!(Path.join(dir, "server.tfvars.json"))
      assert Server.up(Keyword.put(opts, :region, "us-east-1")) == another_place("--name")
      assert File.read!(Path.join(dir, "server.tfvars.json")) == before

      # status, tunnel and down hold a given region to the recorded one too.
      assert Server.status(Keyword.put(opts, :region, "us-east-1")) == another_place("--name")

      # Named as the caller's operator names an installation.
      assert Server.status(
               Keyword.merge(opts, region: "us-east-1", name_option: "--installation")
             ) == another_place("--installation")

      # AWS_PROFILE set later in the shell keeps the recorded profile.
      mock_env("other")
      assert Server.up(opts) == server_up()
      assert vars(dir) == aws_vars(%{"aws_profile" => "acme"})
    end

    test "on AWS, takes exported static keys out of OpenTofu's environment, and runs down and the tunnel's refresh on the provider's module",
         %{opts: opts, dir: dir} do
      mock_tofu()

      assert Server.up(Keyword.merge(opts, provider: "aws")) == server_up()

      env = tofu_env(dir, aws_env())

      assert drain() == [
               {:tofu, tofu_init(dir, "aws"), env},
               {:tofu, tofu_plan(dir, "aws"), env},
               {:tofu, tofu_show(dir, "aws"), env},
               {:tofu, tofu_apply(dir, "aws"), env},
               {:tofu, tofu_output("aws"), env},
               {:tofu, tofu_output("aws"), env}
             ]

      mock_ssh("status: done\n", 0)
      assert Server.status(opts) == status_done()

      assert tofu_runs() == [
               tofu_init(dir, "aws"),
               tofu_refresh(dir, "aws", "aws_instance.server"),
               tofu_output("aws")
             ]

      File.write!(Path.join(dir, "tunnel.sock"), "")
      mock_ssh("", 0)
      assert Server.down(opts) == removed(dir)
      assert tofu_runs() == [tofu_init(dir, "aws"), tofu_destroy(dir, "aws")]
    end

    test "says where to compare the host key on the provider's console", %{opts: opts, dir: dir} do
      mock_tofu(%{
        "apply" => fn ->
          File.write!(
            Path.join(dir, "known_hosts"),
            "#{@address} ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHJW8mIz6TFSkLmac1HAw5DFrXN80G7PEP11G/LYZ4qF\n"
          )

          {"", 0}
        end
      })

      assert Server.up(Keyword.merge(opts, provider: "gcp", gcp_project: "p")) ==
               {:ok,
                %Report{
                  outcome: "The server ehos-trial is up, with k3s.",
                  values: [
                    {"Address", @address},
                    {"SSH host key",
                     "ssh-ed25519 SHA256:YxA5grEqMQtXsV8bgJZJpyV2NJxE/6sj8y9JcQzD1I0\nTrusted on " <>
                       "first contact. Compare it with the serial port output of the instance " <>
                       "in Google Cloud's console."}
                  ],
                  next: ["mix ehos.server tunnel"],
                  secrets: up_secrets()
                }}
    end

    test "on GCP, replaces nothing when the lift would change more than the protection", %{
      opts: opts,
      tmp_dir: tmp_dir
    } do
      mock_tofu(%{
        "show" => {plan_json(["delete", "create"], @gcp_instance), 0},
        lift: {lift_json(%{"machine_type" => "e2-standard-4"}), 0}
      })

      assert Server.up(gcp(opts, replace: true)) ==
               {:error,
                "Lifting the deletion protection from ehos-gcpx would also change " <>
                  "#{@gcp_instance}. Nothing was changed. Turn off deletion_protection on the " <>
                  "instance ehos-gcpx in Google Cloud's console, then run this again"}

      dir = Path.join([tmp_dir, "ehos", "gcpx"])

      assert tofu_runs() == [
               tofu_init(dir, "gcp"),
               tofu_plan(dir, "gcp", ["-replace=#{@gcp_instance}"]),
               tofu_show(dir, "gcp"),
               tofu_lift(dir),
               tofu_show(dir, "gcp", "unprotect.tfplan")
             ]
    end

    test "on GCP, says the protection is lifted when up stops after the lift", %{opts: opts} do
      mock_tofu(%{
        "show" => {plan_json(["delete", "create"], @gcp_instance), 0},
        "apply" => {"Error: quota", 1},
        lift: {lift_json(), 0}
      })

      assert Server.up(gcp(opts, replace: true)) ==
               {:error,
                failed(
                  "tofu apply",
                  "Error: quota",
                  "\nThe deletion protection is lifted from ehos-gcpx; `mix ehos.server up` " <>
                    "turns it back on for a server still there"
                )}
    end

    test "refuses to move an installation to another provider", %{opts: opts, dir: dir} do
      mock_tofu()
      assert Server.up(Keyword.merge(opts, provider: "aws")) == server_up()

      assert Server.up(Keyword.merge(opts, provider: "gcp", gcp_project: "p")) ==
               moved(dir, "aws", "gcp")

      assert place(dir) == %{
               "provider" => "aws",
               "aws_account_id" => @account,
               "aws_profile" => "default",
               "region" => "eu-central-1",
               "ssh_key" => recorded_key(opts)
             }
    end

    # D-127: a destroy and a targeted refresh read no data source, so the project is checked first.
    test "on OVHcloud, refuses down, status and the tunnel when the credentials scope another project",
         %{opts: opts, dir: dir} do
      mock_tofu()
      assert Server.up(Keyword.put(opts, :provider, "ovh")) == server_up()
      _ = drain()

      # The plan that checks the scope, the one these commands make.
      mock_tofu(%{
        "plan" =>
          {"Error: Resource postcondition failed\n\nThe credentials scope another project", 1}
      })

      for command <- [&Server.down/1, &Server.status/1, &Server.tunnel/1] do
        assert command.(opts) ==
                 {:error,
                  "OpenTofu's plan before this command failed, so nothing was changed. If it " <>
                    "says the credentials scope another project than the one ehos-trial was " <>
                    "made in, name the clouds.yaml entry for that project with " <>
                    "`mix ehos.server up --os-cloud ENTRY`, which records it, then run this " <>
                    "command again:\nError: Resource postcondition failed\n\nThe credentials " <>
                    "scope another project"}
      end

      # A refresh-only plan reports a failed condition as a warning, and succeeds: the scope's is
      # a plain one.
      scope = tofu_args("ovh", ["plan", "-input=false", "-var-file=#{dir}/server.tfvars.json"])

      assert tofu_runs() == [
               tofu_init(dir, "ovh"),
               scope,
               tofu_init(dir, "ovh"),
               scope,
               tofu_init(dir, "ovh"),
               scope
             ]
    end

    test "pins the account even when the first apply fails partway", %{opts: opts, dir: dir} do
      mock_tofu(%{"apply" => {"Error: creating EC2 Instance", 1}})

      assert Server.up(Keyword.merge(opts, provider: "aws")) ==
               {:error, failed("tofu apply", "Error: creating EC2 Instance")}

      assert place(dir) == %{
               "provider" => "aws",
               "aws_account_id" => @account,
               "aws_profile" => "default",
               "region" => "eu-central-1",
               "ssh_key" => recorded_key(opts),
               "secrets_told" => false
             }
    end

    test "stops, and says what tofu printed, when it cannot read the account after an apply",
         %{opts: opts, dir: dir} do
      # The first `tofu output` after the apply is the one that reads the account.
      {:ok, outputs} = Agent.start_link(fn -> 0 end)

      mock_tofu(%{
        "output" => fn ->
          case Agent.get_and_update(outputs, &{&1, &1 + 1}) do
            0 ->
              {"Error: Error acquiring the state lock\n", 1}

            _later ->
              {~s({"public_ip": {"value": "#{@address}"}, "account_id": {"value": "#{@account}"}}),
               0}
          end
        end
      })

      assert Server.up(Keyword.merge(opts, provider: "aws")) ==
               {:error, failed("tofu output", "Error: Error acquiring the state lock\n")}

      refute Map.has_key?(place(dir), "aws_account_id")
    end

    test "keeps what tofu printed apart when a failed apply cannot say the account either", %{
      opts: opts
    } do
      mock_tofu(%{
        "apply" => {"Error: creating VPC", 1},
        "output" => {"Error: Error acquiring the state lock\n", 1}
      })

      assert Server.up(Keyword.merge(opts, provider: "aws")) ==
               {:error,
                %EhosPlatform.Failure{
                  said:
                    "`tofu apply` failed with exit status 1.\nThe account it was applied in is " <>
                      "not recorded: `tofu output` failed with exit status 1.",
                  tool_output: [
                    {"tofu apply", "Error: creating VPC"},
                    {"tofu output", "Error: Error acquiring the state lock\n"}
                  ]
                }}
    end

    test "says so when a failed apply leaves the account unrecorded", %{opts: opts, dir: dir} do
      mock_tofu(%{
        "apply" => {"Error: creating VPC", 1},
        "output" => {~s({"public_ip": {"value": null}}), 0}
      })

      assert Server.up(Keyword.merge(opts, provider: "aws")) ==
               {:error,
                failed(
                  "tofu apply",
                  "Error: creating VPC",
                  "\nThe account it was applied in is not recorded: The module did not say its " <>
                    "account_id; run `mix ehos.server up` again to record it"
                )}

      assert place(dir) == %{
               "provider" => "aws",
               "aws_profile" => "default",
               "region" => "eu-central-1",
               "ssh_key" => recorded_key(opts),
               "secrets_told" => false
             }
    end

    test "refuses a plan that replaces the provider's instance without --replace", %{opts: opts} do
      for {provider, instance} <- [
            {"aws", "aws_instance.server"},
            {"gcp", "google_compute_instance.server"}
          ] do
        mock_tofu(%{"show" => {plan_json(["delete", "create"], instance), 0}})
        name = provider <> "x"

        assert Server.up(
                 Keyword.merge(opts,
                   provider: provider,
                   gcp_project: "p",
                   name: name
                 )
               ) == replacing(instance, name)
      end
    end

    test "binds the name to nothing when a first up fails before anything is made", %{
      opts: opts,
      dir: dir
    } do
      mock_tofu(%{"plan" => {"Error: no valid credential sources", 1}})

      assert Server.up(opts) == {:error, no_provider()}

      assert Server.up(Keyword.merge(opts, provider: "aws", aws_profile: "x")) ==
               {:error, failed("tofu plan", "Error: no valid credential sources")}

      refute File.exists?(Path.join(dir, "installation.json"))

      mock_tofu()
      assert Server.up(Keyword.merge(opts, provider: "gcp", gcp_project: "p")) == server_up()
    end

    test "refuses an installation.json it cannot read rather than guessing Oracle", %{
      opts: opts,
      dir: dir
    } do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "installation.json"), ~s({"provider": "aw))

      assert Server.status(opts) ==
               {:error,
                "#{dir}/installation.json cannot be read as an installation's place; restore it"}
    end

    test "says which providers there are, and that GCP needs a project", %{opts: opts} do
      assert Server.up(Keyword.put(opts, :provider, "azure")) ==
               {:error, "The provider is one of aws, gcp, oci, ovh, not \"azure\""}

      assert Server.up(Keyword.put(opts, :provider, "gcp")) ==
               {:error,
                "Name the GCP project with --gcp-project, and sign in with " <>
                  "`gcloud auth application-default login` (D-83)"}
    end

    test "says to try another zone when the provider has no capacity", %{opts: opts} do
      mock_tofu(%{"apply" => {"Error: creating EC2 Instance: InsufficientInstanceCapacity", 1}})

      assert Server.up(Keyword.put(opts, :provider, "aws")) ==
               {:error,
                failed(
                  "tofu apply",
                  "Error: creating EC2 Instance: InsufficientInstanceCapacity",
                  "\nThe provider has no machine of that type in that zone now: run it again " <>
                    "later, or with another --availability-domain (from 0), which picks another " <>
                    "of the region's zones"
                )}
    end
  end

  describe "tunnel/1" do
    setup %{opts: opts, dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "server.tfvars.json"), "{}")
      File.write!(Path.join(dir, "installation.json"), ~s({"provider": "oci"}))
      # A key `tunnel` can find on the server's lines.
      File.write!(opts[:ssh_key] <> ".pub", @operator_line)
      %{opts: opts}
    end

    test "opens the tunnel in the background and writes a kubeconfig only its owner reads",
         %{opts: opts, dir: dir, tmp_dir: tmp_dir} do
      mock_tofu()
      mock_tunnel()

      # A path with nothing a shell reads in it is left unquoted.
      assert Server.tunnel(opts) == tunnel_open(dir, 16_443)

      assert drain() ==
               refreshed(dir) ++
                 [
                   administrators_read(tmp_dir, dir),
                   {:control, "#{dir}/tunnel.sock", "check"},
                   tunnel_opened(tmp_dir, dir, 16_443),
                   kubeconfig_read(tmp_dir, dir)
                 ]

      kubeconfig = Path.join(dir, "kubeconfig")
      assert mode(kubeconfig) == 0o600
      assert mode(Path.join(dir, "tunnel.json")) == 0o600

      assert kubeconfig |> File.read!() |> Jason.decode!() == %{
               "apiVersion" => "v1",
               "kind" => "Config",
               "current-context" => "ehos-trial",
               "clusters" => [
                 %{
                   "name" => "ehos-trial",
                   "cluster" => %{
                     "certificate-authority-data" => "Q0E=",
                     "server" => "https://127.0.0.1:16443"
                   }
                 }
               ],
               "contexts" => [
                 %{
                   "name" => "ehos-trial",
                   "context" => %{"cluster" => "ehos-trial", "user" => "ehos-trial"}
                 }
               ],
               "users" => [
                 %{
                   "name" => "ehos-trial",
                   "user" => %{
                     "client-certificate-data" => "Q0VSVA==",
                     "client-key-data" => "S0VZ"
                   }
                 }
               ]
             }
    end

    # Agreed on eh-os#1836: who this workstation is comes from the server, so a server that cannot
    # say opens no tunnel, rather than one with k3s's admin file for a person of their own.
    test "opens no tunnel when it cannot read the administrators of the server, or has no .pub",
         %{opts: opts, dir: dir} do
      mock_tofu()
      mock_tunnel(administrators: {"The connection to the server was refused", 3})

      assert Server.tunnel(opts) ==
               {:error,
                %EhosPlatform.Failure{
                  said:
                    "ehosctl could not read the administrators of ehos-trial (exit status 3).",
                  tool_output: [{"ssh", "The connection to the server was refused"}]
                }}

      File.rm!(opts[:ssh_key] <> ".pub")
      mock_tunnel()

      assert Server.tunnel(opts) ==
               {:error,
                "ehosctl needs #{opts[:ssh_key]}.pub, the public key of the key that you log in " <>
                  "with, to find the installation administrator whose line holds it. Write it " <>
                  "with `ssh-keygen -y -f #{opts[:ssh_key]}`."}

      refute Enum.any?(drain(), &match?({:tunnel, _script, _log, _args}, &1))
      refute File.exists?(Path.join(dir, "kubeconfig"))
    end

    # ehos-tools#1023: a kubeconfig written in place was readable by others, at the umask's mode
    # or at an earlier file's, until its chmod; one who opened it then reads every credential
    # written into it after.
    test "replaces the kubeconfig whole, so a reader of the one before never reads the new credential",
         %{opts: opts, dir: dir} do
      mock_tofu()
      mock_tunnel()
      kubeconfig = Path.join(dir, "kubeconfig")
      File.write!(kubeconfig, "the kubeconfig before")
      File.chmod!(kubeconfig, 0o644)
      {:ok, reader} = File.open(kubeconfig, [:read, :binary])

      assert Server.tunnel(opts) == tunnel_open(dir, 16_443)

      assert IO.binread(reader, :eof) == "the kubeconfig before"
      assert mode(kubeconfig) == 0o600
    end

    test "says the kubeconfig is not new on a second tunnel to the same server, on another port too",
         %{opts: opts, dir: dir} do
      mock_tofu()
      mock_tunnel()

      assert Server.tunnel(opts) == tunnel_open(dir, 16_443)

      assert Server.tunnel(Keyword.put(opts, :port, 17_443)) ==
               tunnel_open(dir, 17_443, "trial", false)
    end

    test "says the kubeconfig is new when the one before holds no credential it can read",
         %{opts: opts, dir: dir} do
      mock_tofu()
      mock_tunnel()

      for before <- [
            "apiVersion: v1\n",
            ~s({"users":[]}),
            ~s({"users":[{"user":{"client-certificate-data":"Q0VSVA=="}}]})
          ] do
        File.write!(Path.join(dir, "kubeconfig"), before)
        assert Server.tunnel(opts) == tunnel_open(dir, 16_443)
      end
    end

    test "says the kubeconfig is new when the server gives another client credential",
         %{opts: opts, dir: dir} do
      mock_tofu()
      mock_tunnel()
      assert Server.tunnel(opts) == tunnel_open(dir, 16_443)

      made_again =
        String.replace(@k3s_kubeconfig, "client-key-data: S0VZ", "client-key-data: TkVX")

      mock_tunnel(remote: {made_again, 0})

      assert {:ok, report} = Server.tunnel(opts)
      assert {:ok, report} == tunnel_open(dir, 16_443)
      refute inspect(report) =~ "TkVX"
    end

    test "refreshes the state from the provider before it reads the server's address",
         %{opts: opts, dir: dir} do
      record_tunnel(dir, 16_443)
      mock_tofu()
      mock_tunnel(master: {"Master running", 0})

      assert Server.tunnel(opts) == tunnel_open(dir, 16_443)

      assert tofu_runs() == [
               tofu_init(dir),
               tofu_refresh(dir, "oci", "oci_core_instance.server"),
               tofu_output()
             ]
    end

    test "quotes the kubeconfig in what it suggests when the home holds a space",
         %{opts: opts, tmp_dir: tmp_dir} do
      home = Path.join(tmp_dir, "Jane Doe")
      dir = Path.join(home, "trial")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "server.tfvars.json"), "{}")
      File.write!(Path.join(dir, "installation.json"), ~s({"provider": "oci"}))
      record_tunnel(dir, 17_443)
      mock_tofu()
      mock_tunnel(master: {"Master running (pid=42)", 0})

      assert Server.tunnel(Keyword.merge(opts, home: home, port: 17_443)) ==
               tunnel_open(dir, 17_443)
    end

    test "keeps a tunnel that is already open", %{opts: opts, dir: dir, tmp_dir: tmp_dir} do
      mock_tofu()
      mock_tunnel(master: {"Master running (pid=42)", 0})

      record_tunnel(dir, 17_443)
      assert Server.tunnel(Keyword.put(opts, :port, 17_443)) == tunnel_open(dir, 17_443)

      assert drain() ==
               refreshed(dir) ++
                 [
                   administrators_read(tmp_dir, dir),
                   {:control, "#{dir}/tunnel.sock", "check"},
                   kubeconfig_read(tmp_dir, dir)
                 ]
    end

    test "clears a control socket left by a master that is gone before it opens a new one",
         %{opts: opts, dir: dir} do
      mock_tofu()
      socket = Path.join(dir, "tunnel.sock")
      File.write!(socket, "")

      mock_tunnel(
        master: {"Control socket connect: Connection refused", 255},
        open: fn _log ->
          refute File.exists?(socket)
          {"", 0}
        end
      )

      assert Server.tunnel(opts) == tunnel_open(dir, 16_443)
    end

    # eh-os#291: a master that does not answer within the bound is not waited on for ever; its port
    # counts as held, the conservative answer.
    test "counts another installation's tunnel that does not answer in time as holding its port",
         %{opts: opts, dir: dir, tmp_dir: tmp_dir} do
      mock_tofu()
      home = Path.join(tmp_dir, "ehos")
      wedged = Path.join([home, "acme", "tunnel.sock"])
      mock_master_not_answering(wedged)
      mock_tunnel()

      File.mkdir_p!(Path.join(home, "acme"))
      record_tunnel(Path.join(home, "acme"), 16_443)
      File.write!(wedged, "")

      assert Server.tunnel(opts) == tunnel_open(dir, 16_444)

      assert drain() ==
               refreshed(dir) ++
                 [
                   administrators_read(tmp_dir, dir),
                   {:control, "#{dir}/tunnel.sock", "check"},
                   tunnel_opened(tmp_dir, dir, 16_444),
                   kubeconfig_read(tmp_dir, dir)
                 ]
    end

    # eh-os#253, eh-os#285: a port is held by an open tunnel, not by a record alone.
    test "takes a port no other installation's open tunnel holds, and keeps its own",
         %{opts: opts, dir: dir, tmp_dir: tmp_dir} do
      mock_tofu()
      home = Path.join(tmp_dir, "ehos")

      # acme's master answers on its control socket; beta's died in a reboot, leaving its record.
      mock_tunnel(
        masters: %{Path.join([home, "acme", "tunnel.sock"]) => {"Master running (pid=42)", 0}}
      )

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

      assert Server.tunnel(opts) == tunnel_open(dir, 16_444)

      # The other installations are asked in the order the home lists them, which the file
      # system chooses.
      {asked, ran} = Enum.split(drain(), 2)

      assert Enum.sort(asked) == [
               {:control, Path.join([home, "acme", "tunnel.sock"]), "check"},
               {:control, Path.join([home, "beta", "tunnel.sock"]), "check"}
             ]

      assert ran ==
               refreshed(dir) ++
                 [
                   administrators_read(tmp_dir, dir),
                   {:control, "#{dir}/tunnel.sock", "check"},
                   tunnel_opened(tmp_dir, dir, 16_444),
                   kubeconfig_read(tmp_dir, dir)
                 ]

      # acme's own tunnel holds 16443 and is kept there, though trial's is open now.
      assert Server.tunnel(second) == tunnel_open(acme, 16_443, "acme")

      assert drain() ==
               [{:control, "#{acme}/tunnel.sock", "check"}] ++
                 refreshed(acme) ++
                 [
                   administrators_read(tmp_dir, acme),
                   {:control, "#{acme}/tunnel.sock", "check"},
                   kubeconfig_read(tmp_dir, acme)
                 ]
    end

    # eh-os#285: its record names the port, but another's open tunnel holds it now.
    test "gives up its own port when its tunnel died and another's open tunnel holds it",
         %{opts: opts, dir: dir, tmp_dir: tmp_dir} do
      mock_tofu()
      acme = Path.join([tmp_dir, "ehos", "acme"])

      mock_tunnel(
        master: {"Control socket connect: Connection refused", 255},
        masters: %{Path.join(acme, "tunnel.sock") => {"Master running (pid=42)", 0}}
      )

      # trial's master died in a reboot, leaving its record and socket; acme took 16443 since.
      record_tunnel(dir, 16_443)
      File.write!(Path.join(dir, "tunnel.sock"), "")
      File.mkdir_p!(acme)
      record_tunnel(acme, 16_443)
      File.write!(Path.join(acme, "tunnel.sock"), "")

      assert Server.tunnel(opts) == tunnel_open(dir, 16_444)

      assert drain() ==
               [
                 {:control, "#{dir}/tunnel.sock", "check"},
                 {:control, "#{acme}/tunnel.sock", "check"}
               ] ++
                 refreshed(dir) ++
                 [
                   administrators_read(tmp_dir, dir),
                   {:control, "#{dir}/tunnel.sock", "check"},
                   tunnel_opened(tmp_dir, dir, 16_444),
                   kubeconfig_read(tmp_dir, dir)
                 ]
    end

    test "never reads a tunnel's record from what is not a small regular file", %{
      opts: opts,
      dir: dir,
      tmp_dir: tmp_dir
    } do
      mock_tofu()
      home = Path.join(tmp_dir, "ehos")
      mock_tunnel(master: {"Master running (pid=42)", 0})

      # Each would block, never end, or be a record that is not where it seems.
      for name <- ~w(fifo device link), do: File.mkdir_p!(Path.join(home, name))
      {_, 0} = System.cmd("mkfifo", [Path.join([home, "fifo", "tunnel.json"])])
      File.ln_s!("/dev/zero", Path.join([home, "device", "tunnel.json"]))
      record = Path.join(tmp_dir, "elsewhere.json")
      File.write!(record, Jason.encode!(%{address: @address, port: 16_443}))
      File.ln_s!(record, Path.join([home, "link", "tunnel.json"]))

      task = Task.async(fn -> Server.tunnel(opts) end)
      answer = Task.yield(task, 10_000) || Task.shutdown(task)
      assert answer == {:ok, tunnel_open(dir, 16_443)}
    end

    test "opens the tunnel again when the open one goes to another port", %{
      opts: opts,
      dir: dir,
      tmp_dir: tmp_dir
    } do
      mock_tofu()
      record_tunnel(dir, 16_443)
      socket = Path.join(dir, "tunnel.sock")
      File.write!(socket, "")

      mock_tunnel(
        master: {"", 0},
        open: fn _log ->
          refute File.exists?(socket)
          {"", 0}
        end
      )

      assert Server.tunnel(Keyword.put(opts, :port, 17_443)) == tunnel_open(dir, 17_443)

      assert drain() ==
               refreshed(dir) ++
                 [
                   administrators_read(tmp_dir, dir),
                   {:control, socket, "check"},
                   {:control, socket, "exit"},
                   tunnel_opened(tmp_dir, dir, 17_443),
                   kubeconfig_read(tmp_dir, dir)
                 ]

      assert Jason.decode!(File.read!(Path.join(dir, "tunnel.json"))) ==
               %{"address" => @address, "port" => 17_443}
    end

    # eh-os#291: a master that does not answer may still hold the port; its socket is left for the
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
      mock_tofu()
      socket = Path.join(dir, "tunnel.sock")
      File.write!(socket, "")
      record_tunnel(dir, 16_443)
      mock_master_not_answering(socket)

      mock_tunnel(
        open: fn _log ->
          flunk("opened a second tunnel beside a master that may hold the port")
        end
      )

      # Anchored on how only the master is started, not on the path alone, which the control
      # command that hangs beside it names too (ehos-tools#571). The test's own directory is the
      # machine's, escaped as the code escapes it, which `EhosPlatform.ShellTest` pins written
      # out; what the test is about, the home under it, is written out here.
      wedged =
        {:error,
         "The tunnel's ssh master does not answer on #{socket} within 5 seconds. " <>
           "Stop it (`pkill -f -- '-M -S #{tmp_dir |> Shell.pattern() |> quoted()}" <>
           ~S|/Jane O'\''Brien\+work/trial/tunnel\.sock -o ExitOnForwardFailure=yes'`), | <>
           "then run this again"}

      assert Server.tunnel(opts) == wedged
      assert File.exists?(socket)

      assert Server.close_tunnel(opts) == wedged

      # Its record stays, so no other tunnel takes the port it may still hold.
      assert File.exists?(Path.join(dir, "tunnel.json"))
    end

    test "says when the tunnel's record cannot be written", %{opts: opts, dir: dir} do
      mock_tofu()
      File.mkdir_p!(Path.join(dir, "tunnel.json"))
      mock_tunnel(master: {"", 255})

      assert Server.tunnel(opts) ==
               {:error,
                "The tunnel is open, but #{dir}/tunnel.json cannot be written: illegal operation " <>
                  "on a directory. Close it with `mix ehos.server tunnel --close`"}
    end

    test "says what it cannot write instead of failing on the reason", %{opts: opts, dir: dir} do
      mock_tofu()
      record_tunnel(dir, 16_443)
      File.mkdir_p!(Path.join(dir, "kubeconfig"))
      mock_tunnel(master: {"Master running", 0})

      assert Server.tunnel(opts) ==
               {:error, "#{dir}/kubeconfig cannot be written: illegal operation on a directory"}
    end

    test "says why the tunnel did not open, from ssh's log", %{opts: opts, dir: dir} do
      mock_tofu()

      mock_tunnel(
        master: {"", 255},
        open: fn log ->
          File.write!(log, "bind [127.0.0.1]:16443: Address already in use\n")
          {"", 255}
        end
      )

      assert Server.tunnel(opts) ==
               {:error,
                EhosPlatform.Failure.new(
                  "`ssh` could not open the tunnel (exit status 255).\nIf this machine's public " <>
                    "address changed since the server was last brought up, run `mix ehos.server " <>
                    "up` again: it admits the current ones in place of those admitted before. A " <>
                    "network can also reach the internet through more than one address, and SSH " <>
                    "may leave through one that was not seen: give `--ssh-from` each of them, as " <>
                    "`<address>/32`, or the range your provider assigns from, /16 or narrower",
                  "ssh",
                  "bind [127.0.0.1]:16443: Address already in use\n"
                )}

      refute File.exists?(Path.join(dir, "kubeconfig"))
    end

    # ehos-tools#656: found on the first GCP server, made with a key of its own.
    test "names the key the server refused rather than blaming the address", %{
      opts: opts,
      tmp_dir: tmp_dir
    } do
      mock_tofu()

      mock_tunnel(
        open: fn log ->
          File.write!(log, denied() <> "\n")
          {"", 255}
        end
      )

      assert Server.tunnel(opts) ==
               {:error,
                EhosPlatform.Failure.new(
                  "`ssh` could not open the tunnel (exit status 255).\nThe server refused the " <>
                    "SSH key #{tmp_dir}/id_ed25519. Give the private key that the server takes, " <>
                    "your own or the provisioning key, with `--ssh-key`",
                  "ssh",
                  "#{denied()}\n"
                )}
    end

    test "never shows the kubeconfig when it cannot use it", %{opts: opts, dir: dir} do
      mock_tofu()
      record_tunnel(dir, 16_443)

      mock_tunnel(
        master: {"Master running", 0},
        remote: {"client-key-data: S0VZ\nnot: [a kubeconfig", 0}
      )

      assert Server.tunnel(opts) ==
               {:error,
                "The server's kubeconfig is not one cluster and one user, as k3s writes it"}
    end

    test "says how to make the server when there is none", %{opts: opts, tmp_dir: tmp_dir} do
      assert Server.tunnel(Keyword.put(opts, :name, "other")) ==
               {:error,
                "No installation other in #{tmp_dir}/ehos/other. Make it with " <>
                  "`mix ehos.server up --provider PROVIDER`, PROVIDER one of aws, gcp, oci, ovh"}
    end
  end

  describe "down/1" do
    test "closes the tunnel, destroys what the module made, and forgets the host key and kubeconfig",
         %{opts: opts, dir: dir} do
      File.mkdir_p!(dir)

      for file <- ~w(server.tfvars.json known_hosts kubeconfig tunnel.sock),
          do: File.write!(Path.join(dir, file), "")

      # What a write killed before its rename left.
      File.mkdir_p!(Path.join(dir, ".kubeconfig.Zm9vYmFyYmF6.tmp"))
      File.write!(Path.join(dir, ".kubeconfig.Zm9vYmFyYmF6.tmp/kubeconfig"), "a credential")

      File.write!(Path.join(dir, "installation.json"), ~s({"provider": "oci"}))
      mock_tunnel_closing()
      mock_tofu()

      assert Server.down(opts) == removed(dir)

      assert drain() == [
               {:control, "#{dir}/tunnel.sock", "exit"},
               {:tofu, tofu_init(dir), tofu_env(dir)},
               {:tofu, tofu_destroy(dir), tofu_env(dir, [], "false")}
             ]

      refute File.exists?(Path.join(dir, "known_hosts"))
      refute File.exists?(Path.join(dir, "kubeconfig"))
      refute File.exists?(Path.join(dir, ".kubeconfig.Zm9vYmFyYmF6.tmp"))
      assert File.exists?(Path.join(dir, "server.tfvars.json"))
    end

    # eh-os D-199: the next server has none of this one's administrators.
    test "forgets the installation administrator of this workstation", %{opts: opts, dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "server.tfvars.json"), "")

      File.write!(
        Path.join(dir, "installation.json"),
        ~s({"provider": "oci", "administrator": "ada", "administrator_id": "1a2b3c4d"})
      )

      mock_tofu()
      assert Server.down(opts) == removed(dir)
      assert place(dir) == %{"provider" => "oci"}
    end

    test "on GCP, lifts the deletion protection from the server alone before it destroys", %{
      opts: opts,
      dir: dir
    } do
      installation(dir, "gcp")
      mock_tofu(%{lift: {lift_json(), 0}})

      assert Server.down(Keyword.delete(opts, :provider)) == removed(dir)

      env = tofu_env(dir)
      lifting = tofu_env(dir, [], "false")

      assert drain() == [
               {:tofu, tofu_init(dir, "gcp"), env},
               {:tofu, tofu_lift(dir), lifting},
               {:tofu, tofu_show(dir, "gcp", "unprotect.tfplan"), env},
               {:tofu, tofu_apply(dir, "gcp", "unprotect.tfplan"), lifting},
               {:tofu, tofu_destroy(dir, "gcp"), lifting}
             ]

      refute File.exists?(Path.join(dir, "unprotect.tfplan"))
    end

    test "on GCP, lifts nothing from a server whose protection is not on", %{
      opts: opts,
      dir: dir
    } do
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
        mock_tofu(%{lift: {json, 0}})

        assert Server.down(Keyword.delete(opts, :provider)) == removed(dir)

        assert tofu_runs() == [
                 tofu_init(dir, "gcp"),
                 tofu_lift(dir),
                 tofu_show(dir, "gcp", "unprotect.tfplan"),
                 tofu_destroy(dir, "gcp")
               ]
      end
    end

    test "on AWS, whose provider lifts its own protection, and Oracle, destroys at once", %{
      opts: opts,
      dir: dir
    } do
      for {provider, provider_env} <- [{"aws", aws_env()}, {"oci", []}] do
        installation(dir, provider)
        mock_tofu()

        assert Server.down(Keyword.delete(opts, :provider)) == removed(dir)

        assert drain() == [
                 {:tofu, tofu_init(dir, provider), tofu_env(dir, provider_env)},
                 {:tofu, tofu_destroy(dir, provider), tofu_env(dir, provider_env, "false")}
               ]
      end
    end

    test "on GCP, refuses a lift that would change more than the protection, and destroys " <>
           "nothing",
         %{opts: opts, dir: dir} do
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
        mock_tofu(%{lift: {json, 0}})

        assert Server.down(Keyword.delete(opts, :provider)) ==
                 {:error,
                  "Lifting the deletion protection from ehos-trial would also change #{named}. " <>
                    "Nothing was changed. Turn off deletion_protection on the instance " <>
                    "ehos-trial in Google Cloud's console, then run this again"}

        assert tofu_runs() == [
                 tofu_init(dir, "gcp"),
                 tofu_lift(dir),
                 tofu_show(dir, "gcp", "unprotect.tfplan")
               ]
      end
    end

    test "on GCP, says the protection is lifted when the destroy fails after it", %{
      opts: opts,
      dir: dir
    } do
      installation(dir, "gcp")
      mock_tofu(%{"destroy" => {"Error: 503", 1}, lift: {lift_json(), 0}})

      assert Server.down(Keyword.delete(opts, :provider)) ==
               {:error,
                failed(
                  "tofu destroy",
                  "Error: 503",
                  "\nThe deletion protection is lifted from ehos-trial; run `mix ehos.server " <>
                    "down` again to finish removing it, or `mix ehos.server up` to keep it, which " <>
                    "turns the protection back on"
                )}
    end

    test "keeps the host key when the destroy fails", %{opts: opts, dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "server.tfvars.json"), "{}")
      File.write!(Path.join(dir, "installation.json"), ~s({"provider": "oci"}))
      File.write!(Path.join(dir, "known_hosts"), "")
      mock_tofu(%{"destroy" => {"Error: 409-Conflict", 1}})

      assert Server.down(opts) ==
               {:error, failed("tofu destroy", "Error: 409-Conflict")}

      assert File.exists?(Path.join(dir, "known_hosts"))
    end
  end

  # eh-os D-199: an installation administrator's own key and certificate, through the CSR API.
  describe "tunnel/1 for an installation administrator" do
    setup %{opts: opts, dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "server.tfvars.json"), Jason.encode!(oci_vars()))
      File.write!(opts[:ssh_key] <> ".pub", "ssh-ed25519 AAAAa2V5 ada@laptop\n")
      %{ca: TestCA.new(), server_ca: TestCA.new("k3s-server-ca")}
    end

    test "issues a certificate of its own through a CSR it checks, and writes it in the kubeconfig",
         %{opts: opts, dir: dir, ca: ca, server_ca: server_ca} do
      record_administrator(dir, "ada", "1a2b3c4d")
      mock_tofu()
      mock_cluster(ca, server_ca)

      assert {:ok, %Report{values: values, secrets: secrets, warnings: [one_remains]}} =
               Server.tunnel(opts)

      assert {"One installation administrator remains: ada.", _explanation} = one_remains

      assert values == [
               {"Address", "127.0.0.1:16443"},
               {"Context", "ehos-trial"},
               {"Certificate", "ehos-administrator:ada:1a2b3c4d, until 2026-11-20 00:00 UTC"}
             ]

      assert secrets == [
               %Secret{kind: :ssh_key, place: opts[:ssh_key]},
               %Secret{kind: :kubeconfig, place: Path.join(dir, "kubeconfig"), new?: true}
             ]

      calls = cluster_calls()

      # One read of the administrators, for the person and the warnings.
      assert [
               {:ssh, _administrators},
               {:ssh, "sudo cat /var/lib/rancher/k3s/server/tls/server-ca.crt" <> _},
               {:sh, create, created},
               {:sh, approve, approved}
             ] = calls

      assert create =~ "sudo k3s kubectl create --request-timeout=30s -o json -f -"
      assert approve =~ "certificatesigningrequests/$name/approval"
      # One deadline for the wait, each request given what is left of it.
      assert approve =~ ~S[deadline=$(($(date +%s) + 30))]

      assert approve =~
               ~S(c=$(timeout "${left}s" sudo k3s kubectl get --request-timeout="${left}s")

      # A request that fails is tried again while time is left; neither a request nor a pause
      # outlasts the deadline.
      refute approve =~ "left=5"
      assert approve =~ ~S{if [ $((deadline - $(date +%s))) -le 1 ]; then cat "$e"; exit 4; fi}
      refute approve =~ "-gt 1 ]; then sleep 1"
      assert approve =~ ~S[2>"$e") || c=]

      [name, json] = String.split(approved, "\n", parts: 2)
      approval = Jason.decode!(json)
      assert name == get_in(Jason.decode!(created), ["metadata", "name"])
      assert name =~ ~r/\Aehos-administrator-ada-1a2b3c4d-[0-9a-f]{8}\z/
      assert get_in(approval, ["metadata", "uid"]) == "uid-1"
      assert get_in(approval, ["metadata", "resourceVersion"]) == "41"
      assert [%{"type" => "Approved", "status" => "True"}] = approval["status"]["conditions"]

      config = dir |> Path.join("kubeconfig") |> File.read!() |> Jason.decode!()
      [%{"user" => user}] = config["users"]
      [%{"cluster" => cluster}] = config["clusters"]
      assert Base.decode64!(cluster["certificate-authority-data"]) == server_ca.pem
      assert cluster["server"] == "https://127.0.0.1:16443"
      refute File.read!(Path.join(dir, "kubeconfig")) =~ "Q0VSVA=="

      certificate = Base.decode64!(user["client-certificate-data"])
      key = ClientCertificate.read_key(Base.decode64!(user["client-key-data"]))

      assert ClientCertificate.check_certificate(
               certificate,
               key,
               "ehos-administrator:ada:1a2b3c4d"
             ) ==
               :ok

      assert mode(Path.join(dir, "kubeconfig")) == 0o600
    end

    test "keeps a certificate with an hour left, and issues one again with less, or from another CA",
         %{opts: opts, dir: dir, ca: ca, server_ca: server_ca} do
      record_administrator(dir, "ada", "1a2b3c4d")
      mock_tofu()
      mock_cluster(ca, server_ca)

      assert {:ok, _report} = Server.tunnel(opts)
      _issued = cluster_calls()

      # Exactly 1 hour left: kept.
      stub(ClockMock, :utc_now, fn -> ~U[2026-11-19 23:00:00Z] end)
      assert {:ok, %Report{secrets: [_key, %Secret{new?: false}]}} = Server.tunnel(opts)
      assert [{:ssh, _administrators}, {:ssh, _cas}] = cluster_calls()

      stub(ClockMock, :utc_now, fn -> ~U[2026-11-19 23:30:00Z] end)
      assert {:ok, %Report{secrets: [_key, %Secret{new?: true}]}} = Server.tunnel(opts)

      assert [{:ssh, _administrators}, {:ssh, _cas}, {:sh, _create, _}, {:sh, _approve, _}] =
               cluster_calls()

      stub(ClockMock, :utc_now, fn -> ~U[2026-11-19 12:00:00Z] end)
      mock_cluster(TestCA.new(), server_ca)
      assert {:ok, %Report{secrets: [_key, %Secret{new?: true}]}} = Server.tunnel(opts)
    end

    test "issues a certificate again for a kubeconfig whose credential is not text", %{
      opts: opts,
      dir: dir,
      ca: ca,
      server_ca: server_ca
    } do
      record_administrator(dir, "ada", "1a2b3c4d")

      File.write!(
        Path.join(dir, "kubeconfig"),
        Jason.encode!(%{
          "users" => [%{"user" => %{"client-certificate-data" => 1, "client-key-data" => 2}}]
        })
      )

      mock_tofu()
      mock_cluster(ca, server_ca)

      assert {:ok, %Report{secrets: [_key, %Secret{new?: true}]}} = Server.tunnel(opts)
    end

    test "does not approve a CSR the server answers with another key", %{
      opts: opts,
      dir: dir,
      ca: ca,
      server_ca: server_ca
    } do
      record_administrator(dir, "ada", "1a2b3c4d")
      mock_tofu()

      mock_cluster(ca, server_ca, fn created ->
        other =
          ClientCertificate.csr(ClientCertificate.new_key(), "ehos-administrator:ada:1a2b3c4d")

        put_in(created, ["spec", "request"], Base.encode64(other))
      end)

      assert Server.tunnel(opts) ==
               {:error,
                "The certificate signing request on the server is not the one that ehosctl " <>
                  "made. ehosctl did not approve it. Run the command again."}

      assert [{:ssh, _administrators}, {:ssh, _cas}, {:sh, _create, _}] = cluster_calls()
      refute File.exists?(Path.join(dir, "kubeconfig"))
    end

    # eh-os D-199: a folder copied from another workstation names the giver, whose certificate this
    # one must not get; a person removed and added again has a new id. The key decides both.
    test "acts as the administrator whose line holds this workstation's key, whatever the folder records",
         %{opts: opts, dir: dir, ca: ca, server_ca: server_ca} do
      mock_tofu()

      mock_cluster(ca, server_ca, & &1,
        administrators:
          administrators(
            "ssh-ed25519 AAAAa2V5 ehos-administrator:ada:1a2b3c4d\n" <>
              "ssh-ed25519 AAAAb3Rozg== ehos-administrator:bob:5e6f7a8b\n",
            [Administrators.binding("ada", "1a2b3c4d"), Administrators.binding("bob", "5e6f7a8b")]
          )
      )

      for {name, id} <- [{"bob", "5e6f7a8b"}, {"ada", "0f0f0f0f"}] do
        record_administrator(dir, name, id)

        assert {:ok, %Report{values: values, secrets: secrets, warnings: []}} =
                 Server.tunnel(opts)

        assert [
                 _address,
                 _context,
                 {"Certificate", "ehos-administrator:ada:1a2b3c4d, until " <> _}
               ] =
                 values

        assert [%Secret{kind: :ssh_key}, %Secret{kind: :kubeconfig}] = secrets
        assert place(dir)["administrator"] == "ada"
        assert place(dir)["administrator_id"] == "1a2b3c4d"
        assert place(dir)["ssh_key"] == recorded_key(opts)
        File.rm!(Path.join(dir, "kubeconfig"))
      end
    end

    # The decision of 25 November 2026 on eh-os#1836: a person not added yet still reaches the
    # cluster while the server has the key that every administrator shares, and nobody does once
    # each administrator has a key of their own, so that k3s's admin file stays on that server.
    test "copies k3s's admin file and records nobody while the server keeps the shared key",
         %{opts: opts, dir: dir, ca: ca, server_ca: server_ca} do
      mock_tofu()
      bob = "ssh-ed25519 AAAAb3Rozg== ehos-administrator:bob:5e6f7a8b\n"

      for {line, provisioning} <- [
            {"ssh-ed25519 AAAAa2V5 ehos-administrator:shared\n", "ssh-ed25519 AAAAa2V5 operator"},
            {"ssh-ed25519 AAAAa2V5 operator\n", "ssh-ed25519 AAAAa2V5 operator"},
            {"# Added by Google\nssh-ed25519 AAAAa2V5 google-ssh\n", "ssh-ed25519 AAAAa2V5 x"},
            # Another unnamed key, beside the provisioning key on cloud-init's line.
            {"ssh-ed25519 AAAAa2V5 ada@laptop\nssh-ed25519 AAAAcHJvdg== operator\n",
             "ssh-ed25519 AAAAcHJvdg== operator"}
          ] do
        record_administrator(dir, "bob", "5e6f7a8b")

        File.write!(
          Path.join(dir, "server.tfvars.json"),
          Jason.encode!(oci_vars(%{"ssh_public_key" => provisioning}))
        )

        mock_cluster(ca, server_ca, & &1,
          administrators: administrators(line <> bob, [Administrators.binding("bob", "5e6f7a8b")])
        )

        assert {:ok, %Report{values: values, secrets: secrets, warnings: warnings}} =
                 Server.tunnel(opts)

        assert values == [{"Address", "127.0.0.1:16443"}, {"Context", "ehos-trial"}]

        assert secrets == [
                 %Secret{kind: :shared_ssh_key, place: opts[:ssh_key]},
                 %Secret{kind: :k3s_kubeconfig, place: Path.join(dir, "kubeconfig"), new?: true}
               ]

        assert [copied, {"One installation administrator remains: bob.", _why}] = warnings
        assert copied == k3s_kubeconfig_warning("trial")
        refute Map.has_key?(place(dir), "administrator")
        refute Map.has_key?(place(dir), "administrator_id")
        File.rm!(Path.join(dir, "kubeconfig"))
      end
    end

    # On GCP the agent's line keeps the provisioning key once it is a person's: that key is
    # theirs, not the shared one.
    test "refuses a key on no person's line once the server has no shared key", %{
      opts: opts,
      dir: dir,
      ca: ca,
      server_ca: server_ca
    } do
      mock_tofu()

      File.write!(
        Path.join(dir, "server.tfvars.json"),
        Jason.encode!(oci_vars(%{"ssh_public_key" => "ssh-ed25519 AAAAb3Rozg== operator"}))
      )

      bob = "ssh-ed25519 AAAAb3Rozg== ehos-administrator:bob:5e6f7a8b\n"

      for others <- ["", "# Added by Google\nssh-ed25519 AAAAb3Rozg== google-ssh\n"] do
        record_administrator(dir, "bob", "5e6f7a8b")

        # bob's line holds the provisioning key; this workstation's key names nobody.
        mock_cluster(ca, server_ca, & &1,
          administrators:
            administrators(
              others <> "ssh-ed25519 AAAAa2V5 ada@laptop\n" <> bob,
              [Administrators.binding("bob", "5e6f7a8b")]
            )
        )

        assert Server.tunnel(opts) ==
                 {:error,
                  "No line of an installation administrator on ehos-trial holds " <>
                    "#{opts[:ssh_key]}.pub, the key that you log in with. The server no longer " <>
                    "has the key that every administrator shared, so ehosctl does not copy the " <>
                    "admin file of k3s. Ask an installation administrator to add you with " <>
                    "`mix ehos.server admin add NAME --public-key FILE`. Then run " <>
                    "`mix ehos.server tunnel --ssh-key PRIVATE_KEY` with the private key of the " <>
                    "key that they add."}

        assert [{:ssh, _administrators}] = cluster_calls()
        refute File.exists?(Path.join(dir, "kubeconfig"))
      end
    end

    # A folder that records no provisioning key still reaches a server that has no person yet.
    test "copies k3s's admin file for a server with no administrator of their own", %{
      opts: opts,
      dir: dir,
      ca: ca,
      server_ca: server_ca
    } do
      mock_tofu()
      File.write!(Path.join(dir, "server.tfvars.json"), Jason.encode!(%{}))
      File.write!(Path.join(dir, "installation.json"), ~s({"provider": "oci"}))

      mock_cluster(ca, server_ca, & &1,
        administrators: administrators("ssh-ed25519 AAAAa2V5 operator\n")
      )

      assert {:ok, %Report{secrets: [_key, %Secret{kind: :k3s_kubeconfig}]}} = Server.tunnel(opts)
    end

    # `admin add` refuses a key a person holds already: only a file written by hand has two.
    test "refuses when two persons' lines hold this workstation's key", %{
      opts: opts,
      dir: dir,
      ca: ca,
      server_ca: server_ca
    } do
      mock_tofu()
      record_administrator(dir, "ada", "1a2b3c4d")

      mock_cluster(ca, server_ca, & &1,
        administrators:
          administrators(
            "ssh-ed25519 AAAAa2V5 ehos-administrator:ada:1a2b3c4d\n" <>
              "ssh-ed25519 AAAAa2V5 ehos-administrator:bob:5e6f7a8b\n"
          )
      )

      assert Server.tunnel(opts) ==
               {:error,
                "On ehos-trial, the lines of ada and bob hold #{opts[:ssh_key]}.pub, the key " <>
                  "that you log in with, so ehosctl cannot tell which installation administrator you " <>
                  "are. Run the command again with `--administrator NAME`. Ask an installation " <>
                  "administrator to give each person a key of their own."}

      assert [{:ssh, _administrators}] = cluster_calls()
      refute File.exists?(Path.join(dir, "kubeconfig"))
    end

    test "--administrator records the administrator whose line holds this workstation's key", %{
      opts: opts,
      dir: dir,
      ca: ca,
      server_ca: server_ca
    } do
      File.write!(Path.join(dir, "installation.json"), ~s({"provider": "oci"}))
      mock_tofu()

      mock_cluster(ca, server_ca, & &1,
        administrators:
          administrators(
            "ssh-ed25519 AAAAa2V5 ehos-administrator:ada:1a2b3c4d\n" <>
              "ssh-ed25519 AAAAb3Rozg== ehos-administrator:bob:5e6f7a8b\n"
          )
      )

      assert {:ok, %Report{values: [_address, _context, {"Certificate", certificate}]}} =
               Server.tunnel(Keyword.put(opts, :administrator, "ada"))

      assert certificate =~ "ehos-administrator:ada:1a2b3c4d"
      assert place(dir)["administrator"] == "ada"
      assert place(dir)["administrator_id"] == "1a2b3c4d"
      # The key that logged in as ada, in place of the one a copied folder names.
      assert place(dir)["ssh_key"] == recorded_key(opts)

      assert Server.tunnel(Keyword.put(opts, :administrator, "bob")) ==
               {:error,
                "The line of bob on ehos-trial holds another key than #{opts[:ssh_key]}.pub. " <>
                  "Give the private key of bob with `--ssh-key`."}

      assert Server.tunnel(Keyword.put(opts, :administrator, "carol")) ==
               {:error,
                "ehos-trial has no installation administrator named carol. Ask an installation " <>
                  "administrator to add you with `admin add carol --public-key FILE`."}
    end
  end

  describe "close_tunnel/1" do
    test "closes the tunnel through its control socket, and forgets where it went", %{
      opts: opts,
      dir: dir
    } do
      File.mkdir_p!(dir)
      record_tunnel(dir, 16_443)
      File.write!(Path.join(dir, "tunnel.sock"), "")
      mock_tunnel_closing()

      assert Server.close_tunnel(opts) ==
               {:ok, %Report{outcome: "The tunnel to ehos-trial is closed."}}

      refute File.exists?(Path.join(dir, "tunnel.json"))
    end

    test "says so when no tunnel is open", %{opts: opts} do
      assert Server.close_tunnel(opts) ==
               {:ok, %Report{outcome: "No tunnel to ehos-trial is open.", ending: :unchanged}}
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
         %{opts: opts, dir: dir, tmp_dir: tmp_dir} do
      mock_tofu()

      mock_ssh_once(
        "cpus 2\nMemTotal: 12249180\nMemAvailable: 10276344\nload 0.15 0.10 0.05\n---\n" <>
          "status: done\n---\nNAME   STATUS\nehos   Ready\n",
        0
      )

      assert Server.status(opts) ==
               {:ok,
                %Report{
                  outcome: "The server ehos-trial answered.",
                  values: [
                    {"Address", @address},
                    {"CPU", "2, load 0.15 0.10 0.05 (1, 5 and 15 minutes)"},
                    {"Memory", "9.8 GiB available of 11.7 GiB"}
                  ],
                  tool_output: [
                    {"cloud-init status", "status: done\n"},
                    {"kubectl get nodes", "NAME   STATUS\nehos   Ready\n"}
                  ]
                }}

      script =
        ~S[printf 'cpus %s\n' "$(nproc)"; ] <>
          ~S[awk '/^(MemTotal|MemAvailable):/ {print $1, $2}' /proc/meminfo; ] <>
          ~S[printf 'load %s\n' "$(cut -d' ' -f1-3 /proc/loadavg)"; echo ---; ] <>
          ~S[cloud-init status; echo ---; ] <>
          ~S[sudo k3s kubectl get --request-timeout=30s nodes -o wide 2>&1 || echo 'Kubernetes did not answer.']

      assert drain() == refreshed(dir) ++ [{:ssh, ssh_args(tmp_dir, dir, script)}]
    end

    test "reports the node's resources when Kubernetes does not answer", %{opts: opts} do
      mock_tofu()

      mock_ssh_once(
        "cpus 2\nMemTotal: 12249180\nMemAvailable: 10276344\nload 0.01 0.02 0.03\n---\n" <>
          "status: done\n---\nThe connection to the server 127.0.0.1:6443 was refused\n" <>
          "Kubernetes did not answer.\n",
        0
      )

      assert Server.status(opts) ==
               {:ok,
                %Report{
                  outcome: "The server ehos-trial answered.",
                  values: [
                    {"Address", @address},
                    {"CPU", "2, load 0.01 0.02 0.03 (1, 5 and 15 minutes)"},
                    {"Memory", "9.8 GiB available of 11.7 GiB"}
                  ],
                  tool_output: [
                    {"cloud-init status", "status: done\n"},
                    {"kubectl get nodes",
                     "The connection to the server 127.0.0.1:6443 was refused\n" <>
                       "Kubernetes did not answer.\n"}
                  ]
                }}
    end

    test "says what it could not read of the node's resources, whatever else was printed" do
      assert Server.status_report("cpus x\n---\nstatus: done\n---\nNAME\n") ==
               {[{"CPU", "not read"}, {"Memory", "not read"}],
                [{"cloud-init status", "status: done\n"}, {"kubectl get nodes", "NAME\n"}]}

      # A shell's startup file can print a line of its own, or a carriage return.
      assert Server.status_report("cpus 2\n  \r\nload 1 2 3\n---\nstatus: done\n---\nNAME\n") ==
               {[{"CPU", "2, load 1 2 3 (1, 5 and 15 minutes)"}, {"Memory", "not read"}],
                [{"cloud-init status", "status: done\n"}, {"kubectl get nodes", "NAME\n"}]}

      # Output in another form, as from a shell that printed before the script, is kept whole.
      assert Server.status_report("Welcome\n") == {[], [{"the status script", "Welcome\n"}]}
    end

    test "names the command the operator runs, as it is given" do
      opts = [name: "trial", home: "/nonexistent", passphrase: String.duplicate("p", 16)]

      assert Server.status(Keyword.merge(opts, command: "ehosctl server")) ==
               {:error,
                "No installation trial in /nonexistent/trial. Make it with " <>
                  "`ehosctl server up --provider PROVIDER`, PROVIDER one of aws, gcp, oci, ovh"}
    end

    test "names the installation in the commands it suggests, when the caller asks" do
      opts = [name: "trial", home: "/nonexistent", passphrase: String.duplicate("p", 16)]

      named =
        Keyword.merge(opts,
          command: "ehosctl server",
          name_option: "--installation",
          name_in_commands: true
        )

      assert Server.status(named) ==
               {:error,
                "No installation trial in /nonexistent/trial. Make it with " <>
                  "`ehosctl server up --provider PROVIDER --installation trial`, PROVIDER one of " <>
                  "aws, gcp, oci, ovh"}

      assert Server.status(opts) ==
               {:error,
                "No installation trial in /nonexistent/trial. Make it with " <>
                  "`mix ehos.server up --provider PROVIDER`, PROVIDER one of aws, gcp, oci, ovh"}
    end

    test "says to admit this machine's address again when SSH does not answer", %{opts: opts} do
      mock_tofu()
      mock_ssh_once("Operation timed out", 255)

      assert Server.status(opts) ==
               {:error,
                "`ssh` could not reach #{@address}:\nOperation timed out\nIf this machine's " <>
                  "public address changed since the server was last brought up, run " <>
                  "`mix ehos.server up` again: it admits the current ones in place of those " <>
                  "admitted before. A network can also reach the internet through more than one " <>
                  "address, and SSH may leave through one that was not seen: give `--ssh-from` " <>
                  "each of them, as `<address>/32`, or the range your provider assigns from, /16 or narrower"}
    end

    # ehos-tools#656: a refused key is not a changed address.
    test "names the key the server refused, and says to give the one up put on it", %{
      opts: opts,
      dir: dir,
      tmp_dir: tmp_dir
    } do
      # The key `up` put on the server, under another comment: the same key.
      File.write!(
        Path.join(dir, "server.tfvars.json"),
        ~s({"ssh_public_key": "ssh-ed25519 AAAAkey laptop"})
      )

      mock_tofu()
      mock_ssh_once(denied(), 255)

      assert Server.status(with_progress(opts)) ==
               {:error,
                "`ssh` could not reach #{@address}:\n#{denied()}\nThe server refused the SSH " <>
                  "key #{tmp_dir}/id_ed25519. Give the private key that the server takes, your " <>
                  "own or the provisioning key, with `--ssh-key`"}

      assert progress() == []
    end

    test "says when the key the server refused is not the provisioning key", %{
      opts: opts,
      dir: dir,
      tmp_dir: tmp_dir
    } do
      File.write!(
        Path.join(dir, "server.tfvars.json"),
        ~s({"ssh_public_key": "ssh-ed25519 AAAAother laptop"})
      )

      mock_tofu()
      mock_ssh_once(denied(), 255)

      assert Server.status(with_progress(opts)) ==
               {:error,
                "`ssh` could not reach #{@address}:\n#{denied()}\nThe server refused the SSH " <>
                  "key #{tmp_dir}/id_ed25519: its .pub is not the provisioning key, so the server " <>
                  "takes it only when an installation administrator added it with `admin add`. " <>
                  "Give the private key that the server takes, your own or the provisioning key, " <>
                  "with `--ssh-key`"}

      # Not said before: the key of an installation administrator of their own is not the
      # provisioning key, and the server takes it (eh-os D-199).
      assert progress() == []
    end

    test "says when the key up recorded is not on this machine, rather than that it was refused",
         %{opts: opts, dir: dir, tmp_dir: tmp_dir} do
      elsewhere = Path.join(tmp_dir, "elsewhere")

      File.write!(
        Path.join(dir, "installation.json"),
        Jason.encode!(%{"provider" => "oci", "ssh_key" => elsewhere})
      )

      mock_tofu()
      mock_ssh_once(denied(), 255)

      assert Server.status(Keyword.delete(opts, :ssh_key)) ==
               {:error,
                "`ssh` could not reach #{@address}:\n#{denied()}\nThe key #{elsewhere} that " <>
                  "`up` recorded is not on this machine. Give the private key that the server " <>
                  "takes, your own or the provisioning key, with `--ssh-key`"}
    end

    test "refuses a recorded key that is not a path, saying to restore the record", %{
      opts: opts,
      dir: dir
    } do
      path = Path.join(dir, "installation.json")

      # A key `up` records is absolute or under the home, with no `..` and nothing a terminal
      # would act on.
      for key <-
            [42, "", "/keys/id\u0000key", "/keys/id\u0007key", "/keys/id\u200ekey"] ++
              ["/keys/id\u2028key", "id_key", "~user/id_key", "/keys/../id_key", "~/../id_key"] do
        File.write!(path, Jason.encode!(%{"provider" => "oci", "ssh_key" => key}))

        assert Server.status(Keyword.delete(opts, :ssh_key)) ==
                 {:error, "#{path} holds an ssh_key that is not a path; restore it"}
      end
    end

    test "takes the system's home when HOME is not an absolute path of printable characters",
         %{opts: opts, tmp_dir: tmp_dir} do
      mock_tofu()
      mock_ssh("status: done\n", 0)

      for home <- [Path.join(tmp_dir, "home\u200e"), "relative/home"] do
        stub(EnvMock, :get, fn
          "HOME" -> home
          _name -> nil
        end)

        assert Server.status(Keyword.delete(opts, :ssh_key)) ==
                 status_done()
      end

      assert ssh_keys() == List.duplicate(Path.join(@system_home, ".ssh/ehos_oci"), 2)
    end

    test "logs in with ~/.ssh/ehos_oci when up recorded no key, and with a recorded one under home",
         %{opts: opts, dir: dir} do
      opts = Keyword.delete(opts, :ssh_key)
      mock_tofu()
      mock_ssh("status: done\n", 0)

      assert Server.status(opts) == status_done()

      File.write!(
        Path.join(dir, "installation.json"),
        ~s({"provider": "oci", "ssh_key": "~/.ssh/ehos_acme"})
      )

      assert Server.status(opts) == status_done()

      assert ssh_keys() == [
               Path.join(@system_home, ".ssh/ehos_oci"),
               Path.join(@system_home, ".ssh/ehos_acme")
             ]
    end
  end

  describe "remote/2" do
    test "runs a command on the server over SSH and returns its output and status, failures included",
         %{opts: opts, dir: dir, tmp_dir: tmp_dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "server.tfvars.json"), "{}")
      File.write!(Path.join(dir, "installation.json"), ~s({"provider": "oci"}))
      mock_tofu()

      mock_ssh_commands(%{
        "cat /proc/sys/kernel/random/boot_id" => {"b1\n", 0},
        "sudo systemctl reboot" => {"Connection closed", 255}
      })

      assert Server.remote(opts, "cat /proc/sys/kernel/random/boot_id") == {:ok, {"b1\n", 0}}
      assert Server.remote(opts, "sudo systemctl reboot") == {:ok, {"Connection closed", 255}}

      assert for({:ssh, args} <- drain(), do: args) == [
               ssh_args(tmp_dir, dir, "cat /proc/sys/kernel/random/boot_id"),
               ssh_args(tmp_dir, dir, "sudo systemctl reboot")
             ]
    end

    # No OpenTofu is mocked: running it would fail the test.
    test "reaches an address it is given without reading OpenTofu's state", %{
      opts: opts,
      dir: dir,
      tmp_dir: tmp_dir
    } do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "server.tfvars.json"), "{}")
      File.write!(Path.join(dir, "installation.json"), ~s({"provider": "oci"}))
      mock_ssh_once("", 0)

      assert Server.remote(Keyword.put(opts, :address, "198.51.100.9"), "true") == {:ok, {"", 0}}

      assert drain() == [
               {:ssh,
                ssh_options(Path.join(tmp_dir, "id_ed25519"), dir) ++
                  ["ubuntu@198.51.100.9", "true"]}
             ]
    end

    test "says how to make the server when there is none", %{opts: opts, dir: dir} do
      assert Server.remote(opts, "true") ==
               {:error,
                "No installation trial in #{dir}. Make it with `mix ehos.server up --provider " <>
                  "PROVIDER`, PROVIDER one of aws, gcp, oci, ovh"}
    end
  end

  describe "dir/1" do
    test "keeps installations under the operator's home when :home is from ~/",
         %{tmp_dir: tmp_dir} do
      assert Server.dir(env: EnvMock) == Path.join(@system_home, ".ehos/trial")

      stub(EnvMock, :get, fn "HOME" -> tmp_dir end)

      assert Server.dir(home: "~/installs", name: "check", env: EnvMock) ==
               Path.join(tmp_dir, "installs/check")
    end
  end

  describe "portable_path/2" do
    test "keeps the path as given when the home is the root or the path itself" do
      assert Server.portable_path("/srv/keys/ehos", "/") == "/srv/keys/ehos"
      assert Server.portable_path("/home/ada", "/home/ada") == "/home/ada"
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
      refused =
        {:error, "The server's kubeconfig is not one cluster and one user, as k3s writes it"}

      assert Server.rewrite_kubeconfig("clusters: []\nusers: []\n", "ehos-trial", 16_443) ==
               refused

      assert Server.rewrite_kubeconfig("[", "ehos-trial", 16_443) == refused
    end
  end

  describe "detect_addresses/2" do
    # ehos-tools#157: each service is asked more than once, and every address any gave is kept.
    test "keeps every address the services gave, once each, in the order first seen" do
      seen = mock_public_address_alternating("77.65.103.58", "83.8.86.65")

      # Which service gave which address, and in what order they were asked, is the order the
      # asks ran in, which no test chooses.
      assert {:ok, addresses} = Server.detect_addresses(PublicAddressMock)
      assert Enum.sort(addresses) == ["77.65.103.58", "83.8.86.65"]

      assert Enum.sort(Agent.get(seen, & &1)) == [
               "https://api.ipify.org",
               "https://api.ipify.org",
               "https://checkip.amazonaws.com",
               "https://checkip.amazonaws.com",
               "https://ipv4.icanhazip.com",
               "https://ipv4.icanhazip.com"
             ]
    end

    test "leaves out a service that fails while another answers" do
      mock_public_addresses({:error, "timeout"}, {:ok, "198.51.100.4"})

      assert Server.detect_addresses(PublicAddressMock) == {:ok, ["198.51.100.4"]}
    end

    test "counts an ask that takes too long as that service's failure" do
      mock_ask_failing(:hangs, "https://api.ipify.org")

      {elapsed_us, result} = :timer.tc(fn -> Server.detect_addresses(PublicAddressMock, 200) end)
      assert result == {:ok, ["198.51.100.4"]}
      # The asks wait together, not in turns of the machine's cores.
      assert elapsed_us < 400_000

      mock_ask_failing(:hangs)

      assert Server.detect_addresses(PublicAddressMock, 50) ==
               {:error,
                "checkip.amazonaws.com: it did not answer in time; api.ipify.org: it did not " <>
                  "answer in time; ipv4.icanhazip.com: it did not answer in time"}
    end

    # ehos-tools#544: the crash stops neither this process nor, through the task's link, kills it.
    test "counts an ask that crashed as that service's failure, and says nothing of why" do
      mock_ask_failing(:crashes, "https://api.ipify.org")

      assert Server.detect_addresses(PublicAddressMock) == {:ok, ["198.51.100.4"]}

      mock_ask_failing(:crashes)

      assert Server.detect_addresses(PublicAddressMock) ==
               {:error,
                "checkip.amazonaws.com: its ask failed; api.ipify.org: its ask failed; " <>
                  "ipv4.icanhazip.com: its ask failed"}
    end

    # A caller that traps exits, as ehosctl does, gets the task's death as a message.
    test "counts a task killed by a process linked to it as that service's failure" do
      Process.flag(:trap_exit, true)
      mock_ask_failing(:killed, "https://api.ipify.org")

      assert Server.detect_addresses(PublicAddressMock) == {:ok, ["198.51.100.4"]}
    end

    test "names each service's failure when none answers" do
      mock_public_address_failing("timeout")

      assert Server.detect_addresses(PublicAddressMock) ==
               {:error,
                "checkip.amazonaws.com: timeout; api.ipify.org: timeout; ipv4.icanhazip.com: timeout"}
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

  # A plan that changes nothing: what it reads of a data source is no change either.
  defp unchanged_plan,
    do:
      Jason.encode!(%{
        "resource_changes" => [
          %{
            "address" => "data.oci_identity_availability_domains.ads",
            "change" => %{"actions" => ["read"]}
          },
          %{"address" => "oci_core_security_list.this", "change" => %{"actions" => ["no-op"]}},
          %{"address" => "oci_core_instance.server", "change" => %{"actions" => ["no-op"]}}
        ]
      })

  # An Oracle instance's attributes, as a plan shows them, with a flex shape of that size.
  defp shape(ocpus, memory),
    do: %{
      "shape_config" => [%{"ocpus" => ocpus, "memory_in_gbs" => memory, "vcpus" => 2 * ocpus}]
    }

  # OpenTofu on a server that exists: the plan's attributes before are what the last apply made,
  # and after them the size in the variables, else the module's default of 2 OCPUs and 12 GB; an
  # SSH key or a firewall rule changed besides, so the instance is always updated.
  defp mock_oracle_server do
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

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  # GCP's options, for `up` on GCP, with `extra`.
  defp gcp(opts, extra),
    do: Keyword.merge(opts, [provider: "gcp", gcp_project: "p", name: "gcpx"] ++ extra)

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

  # A checkout under `root` whose Oracle module holds `variables`.
  defp modules(root, variables) do
    module = Path.join(root, "src/deploy/tofu/oci")
    File.mkdir_p!(module)
    File.write!(Path.join(module, "variables.tf"), variables)
    Source.checkout(Path.join(root, "src"))
  end

  # What `up` answers when it made the server `name`, and the secrets it names, new when the plan
  # changed the server: those of the key `:ssh_key` gives, else the one the setup made.
  defp server_up(name \\ "trial", expected \\ []) do
    {:ok,
     %Report{
       outcome: "The server ehos-#{name} is up, with k3s.",
       values: [{"Address", @address}],
       next: ["mix ehos.server tunnel"],
       secrets: up_secrets(name, expected)
     }}
  end

  defp up_secrets(name \\ "trial", expected \\ []) do
    changed? = Keyword.get(expected, :changed?, true)
    dir = Path.join(Process.get(:home), name)

    [
      %Secret{kind: :state_passphrase, place: "EHOS_STATE_PASSPHRASE", new?: changed?},
      %Secret{kind: :encrypted_state, place: Path.join(dir, "terraform.tfstate"), new?: changed?},
      %Secret{
        kind: Keyword.get(expected, :ssh_key_kind, :shared_ssh_key),
        place: Keyword.get_lazy(expected, :ssh_key, fn -> Process.get(:ssh_key) end),
        new?: changed?
      }
    ]
  end

  # What `up` says before it plans, with SSH admitted from this machine's address.
  defp making(name \\ "trial"),
    do:
      {:step,
       "Making the server ehos-#{name}, SSH admitted from 198.51.100.4/32; this takes a few minutes"}

  # What `up` says of a server whose address was 192.0.2.1 before the apply.
  defp address_changed do
    {:warning, "The address of ehos-trial changed from 192.0.2.1 to #{@address}.",
     "Oracle Cloud can give the old address to someone else. Remove the old address now from " <>
       "each rule that admits it, such as a mail relay's rule. Stop the pipelines that still " <>
       "name it. Give the new address to each rule and pipeline that needs it.\nA console's " <>
       "host of sslip.io " <>
       "names the old address too: install EHOS again with --host ehos.203-0-113-7.sslip.io, " <>
       "which every application's address follows. A host of your own needs its DNS record " <>
       "changed instead."}
  end

  defp first_boot_failed(output) do
    {:error,
     "The server's first boot failed (exit status 1). Its log is " <>
       "/var/log/cloud-init-output.log on the server:\n" <> output}
  end

  # What `up` answers when SSH times out, with SSH admitted from this machine's address.
  defp never_answered do
    {:error,
     "The server at #{@address} never answered SSH:\nssh: connect to host #{@address} port 22: " <>
       "Operation timed out\nSSH is admitted from 198.51.100.4/32 only. If this machine's " <>
       "public address changed since the server was last brought up, run `mix ehos.server up` " <>
       "again: it admits the current ones in place of those admitted before. A network can " <>
       "also reach the internet through more than one address, and SSH may leave through one " <>
       "that was not seen: give `--ssh-from` each of them, as `<address>/32`, or the range " <>
       "your provider assigns from, /16 or narrower"}
  end

  # What `up` answers to a plan that replaces the server, without --replace.
  defp replacing(instance \\ "oci_core_instance.server", name \\ "trial") do
    {:error,
     "Applying this would remove or replace #{instance}, and everything on ehos-#{name} with " <>
       "it. Nothing was changed. If that is meant, run `mix ehos.server up` again with " <>
       "--replace; a different --availability-domain than before is a different server"}
  end

  defp no_provider do
    "Name the cloud to make ehos-trial in with --provider aws, gcp, oci, ovh; EHOS does not " <>
      "choose one for you. The server stays there: every later command reads it from the " <>
      "installation"
  end

  # What `up` answers when ehos-trial, in `dir`, is on `from`, and is asked to be on `to`.
  defp moved(dir, from, to) do
    {:error,
     "ehos-trial is on #{from}, not #{to}. Choose another --name for a server on #{to}; once " <>
       "`mix ehos.server down` has removed this one, #{dir} can be deleted"}
  end

  # What a command answers when asked for ehos-trial in us-east-1, made in eu-central-1, naming
  # the installation by `option`.
  defp another_place(option) do
    {:error,
     "ehos-trial was made in another place than this asks (region eu-central-1 → us-east-1): " <>
       "that would make a second server and leave the first running where no command reaches " <>
       "it. Nothing was changed. Give the options it was made with (on Oracle, the profile in " <>
       "~/.oci/config it was made with), or choose another #{option}"}
  end

  # What `status` answers when the server printed only cloud-init's `status: done`.
  defp status_done do
    {:ok,
     %Report{
       outcome: "The server ehos-trial answered.",
       values: [{"Address", @address}],
       tool_output: [{"the status script", "status: done\n"}]
     }}
  end

  # The server is gone, and its folder stays with the state, which `up` makes it again from, or
  # which the operator removes (ehos-tools#1016).
  defp removed(dir),
    do:
      {:ok,
       %Report{
         outcome: "The server ehos-trial and everything made with it are removed.",
         secrets: [%Secret{kind: :encrypted_state, place: Path.join(dir, "terraform.tfstate")}],
         warnings: [
           {"The folder of the installation trial stays on this computer, with its encrypted state.",
            "mix ehos.server up makes the server again from it.\n" <>
              "If you do not make the server again, remove the folder:\n" <>
              "  rm -r #{Shell.word(dir)}\n" <>
              "Then remove the copy of the folder and the state passphrase from the password " <>
              "manager that the installation administrators share.\n" <>
              "Keep the passphrase if another installation uses it.\n" <>
              "Keep the SSH key if you use it for another server.\n" <>
              "Keep OpenBao's key while you keep its snapshots."}
         ]
       }}

  # The place `up` recorded in `dir`.
  defp place(dir), do: dir |> Path.join("installation.json") |> File.read!() |> Jason.decode!()

  # The variables `up` wrote in `dir`.
  defp vars(dir), do: dir |> Path.join("server.tfvars.json") |> File.read!() |> Jason.decode!()

  # The variables `up` writes for ehos-trial on Oracle by default, with `changed`.
  defp oci_vars(changed \\ %{}) do
    Map.merge(
      %{
        "name" => "trial",
        "tenancy_ocid" => @tenancy,
        "region" => "eu-frankfurt-1",
        "oci_profile" => "DEFAULT",
        "availability_domain" => 0,
        "ssh_public_key" => "ssh-ed25519 AAAAkey operator",
        "ssh_from" => ["198.51.100.4/32"]
      },
      changed
    )
  end

  # The variables `up` writes for ehos-trial on AWS once the account is pinned, with `changed`.
  defp aws_vars(changed) do
    Map.merge(
      %{
        "name" => "trial",
        "region" => "eu-central-1",
        "aws_account_id" => @account,
        "availability_domain" => 0,
        "ssh_public_key" => "ssh-ed25519 AAAAkey operator",
        "ssh_from" => ["198.51.100.4/32"]
      },
      changed
    )
  end

  # OpenTofu, each run recorded as `{:tofu, args, env}`. A command in `answers` answers as given
  # there, or by calling what is given, with :lift for the lift's `show` and :unprotect for its
  # `apply`; every other answers as `tofu/1`.
  defp mock_tofu(answers \\ %{}) do
    test = self()

    stub(CommandRunnerMock, :run_env, fn "tofu", [_chdir, command | _] = args, env ->
      send(test, {:tofu, args, env})

      case Map.fetch(answers, answer_key(command, args)) do
        {:ok, answer} when is_function(answer, 0) -> answer.()
        {:ok, answer} -> answer
        :error -> tofu(args)
      end
    end)
  end

  defp answer_key(command, args) do
    lift? = Enum.any?(args, &String.ends_with?(&1, "unprotect.tfplan"))

    cond do
      command == "show" and lift? -> :lift
      command == "apply" and lift? -> :unprotect
      true -> command
    end
  end

  # OpenTofu printing `before` and `after_` around the JSON it answers with.
  defp mock_tofu_warning(before, after_) do
    stub(CommandRunnerMock, :run_env, fn "tofu", args, _env ->
      case tofu(args) do
        {"{" <> _ = json, 0} -> {before <> json <> after_, 0}
        other -> other
      end
    end)
  end

  # OpenTofu writing the state readable by others, as it does, on every run.
  defp mock_tofu_writing_state(dir) do
    stub(CommandRunnerMock, :run_env, fn "tofu", args, _env ->
      state = Path.join(dir, "terraform.tfstate")
      File.write!(state, "{}")
      File.chmod!(state, 0o644)
      tofu(args)
    end)
  end

  # SSH and the shell around a tunnel, each run recorded. A control command (`-O`), recorded as
  # `{:control, socket, command}`, answers as `:masters` says for its socket, else as `:master`
  # does: by default, no master there. Opening the tunnel, recorded as
  # `{:tunnel, script, log, args}`, answers as `:open` does given its log; anything else run over
  # SSH, recorded as `{:ssh, args}`, answers `:remote`, by default the kubeconfig k3s wrote.
  defp mock_tunnel(answers \\ []) do
    test = self()

    master =
      Keyword.get(answers, :master, {"Control socket connect: No such file or directory", 255})

    masters = Keyword.get(answers, :masters, %{})
    open = Keyword.get(answers, :open, fn _log -> {"", 0} end)
    remote = Keyword.get(answers, :remote, {@k3s_kubeconfig, 0})

    stub(CommandRunnerMock, :run, fn
      "ssh", ["-S", socket, "-O", command | _] ->
        send(test, {:control, socket, command})
        Map.get(masters, socket, master)

      "sh", ["-c", script, log | args] ->
        send(test, {:tunnel, script, log, args})
        open.(log)

      "ssh", args ->
        send(test, {:ssh, args})

        if List.last(args) =~ "kubectl get",
          do: Keyword.get(answers, :administrators, {administrators(@shared_line), 0}),
          else: remote
    end)
  end

  # The master on `socket` does not answer within the bound; every other control command runs.
  defp mock_master_not_answering(socket) do
    stub(CommandRunnerMock, :run_bounded, fn
      "ssh", ["-F", "none", "-S", ^socket | _], 5_000 -> {:error, :timeout}
      "ssh", ["-F", "none" | args], 5_000 -> CommandRunnerMock.run("ssh", args)
    end)
  end

  # The tunnel's master told to exit through its control socket, once, recorded as
  # `{:control, socket, "exit"}`.
  defp mock_tunnel_closing do
    test = self()

    expect(CommandRunnerMock, :run, fn "ssh", ["-S", socket, "-O", "exit" | _] ->
      send(test, {:control, socket, "exit"})
      {"", 0}
    end)
  end

  # SSH run once, recorded as `{:ssh, args}`, answering `output` with `status`.
  defp mock_ssh_once(output, status) do
    test = self()

    expect(CommandRunnerMock, :run, fn "ssh", args ->
      send(test, {:ssh, args})
      {output, status}
    end)
  end

  # SSH run once for each command in `answers`, recorded as `{:ssh, args}`, answering as given
  # there.
  defp mock_ssh_commands(answers) do
    test = self()

    expect(CommandRunnerMock, :run, map_size(answers), fn "ssh", args ->
      send(test, {:ssh, args})
      Map.fetch!(answers, List.last(args))
    end)
  end

  # SSH, each run recorded as `{:ssh, args}`, answering `output` with `status`.
  defp mock_ssh(output, status) do
    test = self()

    stub(CommandRunnerMock, :run, fn "ssh", args ->
      send(test, {:ssh, args})
      {output, status}
    end)
  end

  # SSH, each run recorded as `{:ssh, args}`: refused on the first try, and finding the first
  # boot done on the second.
  defp mock_ssh_up_on_second_try do
    test = self()

    # The third reads the administrators, after the first boot.
    expect(CommandRunnerMock, :run, 3, fn "ssh", args ->
      send(test, {:ssh, args})

      case Process.get(:ssh_tries, 0) do
        0 ->
          Process.put(:ssh_tries, 1)
          {"ssh: connect to host #{@address} port 22: Connection refused", 255}

        _ ->
          {"status: done\nboot_status_code: enabled-by-generator\n", 0}
      end
    end)
  end

  # Every variable in the environment set to `value`.
  defp mock_env(value), do: stub(EnvMock, :get, fn _name -> value end)

  defp mock_no_address_asked,
    do: expect(PublicAddressMock, :ask, 0, fn _service -> {:ok, "198.51.100.4"} end)

  # checkip.amazonaws.com answering `amazon`, and the other services `other`.
  defp mock_public_addresses(amazon, other) do
    stub(PublicAddressMock, :ask, fn
      "https://checkip.amazonaws.com" -> amazon
      _service -> other
    end)
  end

  # Six asks, answered `first` and `second` in turns, whichever service asks; the services asked,
  # latest first, are kept in the agent returned.
  defp mock_public_address_alternating(first, second) do
    {:ok, seen} = Agent.start_link(fn -> [] end)

    expect(PublicAddressMock, :ask, 6, fn service ->
      n = Agent.get_and_update(seen, &{length(&1), [service | &1]})
      if rem(n, 2) == 0, do: {:ok, first}, else: {:ok, second}
    end)

    seen
  end

  # Every service but `except` failing `how`: never answering, raising, or killed through a
  # process linked to it; `except` answers 198.51.100.4.
  defp mock_ask_failing(how, except \\ nil) do
    stub(PublicAddressMock, :ask, fn
      ^except ->
        {:ok, "198.51.100.4"}

      _service ->
        fail(how)
    end)
  end

  defp fail(:hangs), do: Process.sleep(:infinity)
  defp fail(:crashes), do: raise("fixture crash")

  defp fail(:killed) do
    spawn_link(fn -> exit(:fixture_reason) end)
    Process.sleep(:infinity)
  end

  defp mock_public_address_failing(reason),
    do: stub(PublicAddressMock, :ask, fn _service -> {:error, reason} end)

  # A clock that is `seconds` later each time it is read.
  defp mock_clock_advancing(seconds) do
    stub(ClockMock, :utc_now, fn ->
      read = Process.get(:clock_reads, 0)
      Process.put(:clock_reads, read + 1)
      DateTime.add(~U[2026-11-19 12:00:00Z], read * seconds)
    end)
  end

  defp with_progress(opts) do
    test = self()
    Keyword.put(opts, :progress, &send(test, {:progress, &1}))
  end

  # `dir` made read-only once `up` says it makes the server: after the variables are written,
  # before the place and the key are recorded. Made writable again after the test, so its
  # tmp_dir can be removed.
  defp read_only_once_making(opts, dir) do
    progress = Keyword.get(opts, :progress, fn _event -> :ok end)
    on_exit(fn -> File.chmod(dir, 0o700) end)

    Keyword.put(opts, :progress, fn
      {:step, "Making the server" <> _} = event ->
        File.chmod!(dir, 0o500)
        progress.(event)

      event ->
        progress.(event)
    end)
  end

  # ehos-trial made by `up` with the key `opts` gives, as before `up` recorded keys, and a default
  # key under `tmp_dir`, the operator's home, that is another: the default's path.
  defp made_before_keys_were_recorded(opts, dir, tmp_dir) do
    mock_tofu()
    mock_ssh("status: done\n", 0)
    {:ok, _made} = Server.up(opts)
    File.write!(Path.join(dir, "terraform.tfstate"), "encrypted")
    installation = Path.join(dir, "installation.json")
    place = installation |> File.read!() |> Jason.decode!() |> Map.delete("ssh_key")
    File.write!(installation, Jason.encode!(place))
    default = Path.join([tmp_dir, ".ssh", "ehos_oci"])
    File.mkdir_p!(Path.dirname(default))
    File.write!(default <> ".pub", "ssh-ed25519 AAAAdefault operator\n")
    _made = drain()
    default
  end

  defp record_administrator(dir, name, id),
    do:
      File.write!(
        Path.join(dir, "installation.json"),
        Jason.encode!(%{"provider" => "oci", "administrator" => name, "administrator_id" => id})
      )

  # The server of an installation with installation administrators: its CAs, the CSR it creates
  # (as `created` changes it), its approval, which `ca` answers with a certificate for the key in
  # the CSR until 2026-11-20 00:00, and the administrators' read. The tunnel opens, and nothing
  # else answers. Each call is recorded as `{:ssh, command}` or `{:sh, command, input}`.
  defp mock_cluster(ca, server_ca, created \\ & &1, answers \\ []) do
    test = self()
    marker = "\n--- ehosctl client ca ---\n"

    stub(CommandRunnerMock, :run, fn
      "ssh", ["-S", _socket, "-O", _command | _] ->
        {"Control socket connect: No such file or directory", 255}

      "sh", ["-c", ~S(exec ssh "$@" <"$0"), input | args] ->
        command = List.last(args)
        input = File.read!(input)
        send(test, {:cluster, {:sh, command, input}})

        cond do
          command =~ "kubectl create" ->
            request = Jason.decode!(input)

            metadata =
              Map.merge(request["metadata"], %{"uid" => "uid-1", "resourceVersion" => "41"})

            {request |> Map.put("metadata", metadata) |> created.() |> Jason.encode!(), 0}

          command =~ "/approval" ->
            [_name, json] = String.split(input, "\n", parts: 2)
            csr = json |> Jason.decode!() |> get_in(["spec", "request"]) |> Base.decode64!()
            user = "ehos-administrator:" <> ((json =~ "ada" && "ada:1a2b3c4d") || "bob:5e6f7a8b")

            pem =
              TestCA.sign(ca, TestCA.requested_key(csr), user, "261119080000Z", "261120000000Z")

            {Base.encode64(pem) <> "\n", 0}
        end

      "sh", ["-c", _tunnel, _log | _args] ->
        {"", 0}

      "ssh", args ->
        command = List.last(args)
        send(test, {:cluster, {:ssh, command}})

        cond do
          command =~ "server-ca.crt" ->
            {server_ca.pem <> String.trim_leading(marker) <> ca.pem, 0}

          command =~ "kubectl get" ->
            administrators_answer(answers[:administrators])

          command =~ "k3s.yaml" ->
            {@k3s_kubeconfig, 0}
        end
    end)
  end

  # By default, ada's line with this workstation's key, and her binding.
  defp administrators_answer(nil),
    do:
      {administrators("ssh-ed25519 AAAAa2V5 ehos-administrator:ada:1a2b3c4d\n", [
         Administrators.binding("ada", "1a2b3c4d")
       ]), 0}

  defp administrators_answer(administrators), do: {administrators, 0}

  defp cluster_calls do
    receive do
      {:cluster, call} -> [call | cluster_calls()]
    after
      0 -> []
    end
  end

  # What the read of the installation administrators prints for `keys`, with no binding, role
  # or CSR.
  defp administrators(keys, bindings \\ []) do
    marker = "\n--- ehosctl administrators ---\n"
    empty = ~s({"items": []})

    Base.encode16(:crypto.hash(:sha256, keys), case: :lower) <>
      "\n" <>
      Base.encode64(keys) <>
      marker <> Jason.encode!(%{"items" => bindings}) <> marker <> empty <> marker <> empty
  end

  # The SSH key `opts` gives, as `up` records it in `installation.json`.
  defp recorded_key(opts), do: Server.portable_path(opts[:ssh_key], @system_home)

  # The key each SSH run since the last drain logged in with, in order.
  defp ssh_keys, do: for({:ssh, ["-i", key | _args]} <- drain(), do: key)

  # What OpenSSH prints when the server refuses every key it was offered.
  defp denied, do: "ubuntu@#{@address}: Permission denied (publickey)."

  # The progress lines said since the last drain.
  defp progress, do: for({:progress, line} <- drain(), do: line)

  # The arguments of each OpenTofu run since the last drain.
  defp tofu_runs, do: for({:tofu, args, _env} <- drain(), do: args)

  # OpenTofu's arguments for `args` on the provider's module.
  defp tofu_args(provider, args),
    do: ["-chdir=/src/eh-os/deploy/tofu/#{provider}" | args] ++ ["-no-color"]

  defp tofu_init(dir, provider \\ "oci") do
    tofu_args(provider, [
      "init",
      "-input=false",
      "-reconfigure",
      "-lockfile=readonly",
      "-backend-config=path=#{dir}/terraform.tfstate"
    ])
  end

  # `up`'s plan, from the variables beside the recorded ones.
  defp tofu_plan(dir, provider \\ "oci", extra \\ []) do
    tofu_args(provider, [
      "plan",
      "-input=false",
      "-out=#{dir}/up.tfplan",
      "-var-file=#{dir}/server.tfvars.json.next" | extra
    ])
  end

  defp tofu_show(dir, provider \\ "oci", plan \\ "up.tfplan"),
    do: tofu_args(provider, ["show", "-json", "#{dir}/#{plan}"])

  defp tofu_apply(dir, provider \\ "oci", plan \\ "up.tfplan"),
    do: tofu_args(provider, ["apply", "-input=false", "-auto-approve", "#{dir}/#{plan}"])

  defp tofu_output(provider \\ "oci"), do: tofu_args(provider, ["output", "-json"])

  # The plan that lifts GCP's deletion protection from the server alone.
  defp tofu_lift(dir) do
    tofu_args("gcp", [
      "plan",
      "-input=false",
      "-out=#{dir}/unprotect.tfplan",
      "-target=#{@gcp_instance}",
      "-var-file=#{dir}/server.tfvars.json"
    ])
  end

  # The refresh of `instance` alone, before its address is read.
  defp tofu_refresh(dir, provider, instance) do
    tofu_args(provider, [
      "apply",
      "-refresh-only",
      "-target=#{instance}",
      "-input=false",
      "-auto-approve",
      "-var-file=#{dir}/server.tfvars.json"
    ])
  end

  defp tofu_destroy(dir, provider \\ "oci") do
    tofu_args(provider, [
      "destroy",
      "-input=false",
      "-auto-approve",
      "-var-file=#{dir}/server.tfvars.json"
    ])
  end

  # OpenTofu's environment for the installation in `dir`, with the provider's own after it.
  defp tofu_env(dir, provider_env \\ [], protection \\ nil) do
    [
      {"TF_VAR_state_passphrase", @passphrase},
      {"TF_VAR_deletion_protection", protection},
      {"TF_DATA_DIR", "#{dir}/tofu"},
      {"TF_PLUGIN_CACHE_DIR", "#{Path.dirname(dir)}/plugin-cache"},
      {"TF_IN_AUTOMATION", "1"},
      {"TF_CLI_ARGS", nil},
      {"TF_CLI_ARGS_init", nil},
      {"TF_CLI_ARGS_plan", nil},
      {"TF_CLI_ARGS_apply", nil},
      {"TF_CLI_ARGS_destroy", nil},
      {"TF_CLI_ARGS_output", nil},
      {"TF_CLI_ARGS_show", nil} | provider_env
    ]
  end

  # AWS's credentials and profile from the operator's shell, which OpenTofu never sees.
  defp aws_env do
    for name <- [
          "AWS_ACCESS_KEY_ID",
          "AWS_SECRET_ACCESS_KEY",
          "AWS_SESSION_TOKEN",
          "AWS_SECURITY_TOKEN",
          "AWS_ACCESS_KEY",
          "AWS_SECRET_KEY",
          "AWS_PROFILE",
          "AWS_DEFAULT_PROFILE",
          "AWS_WEB_IDENTITY_TOKEN_FILE",
          "AWS_ROLE_ARN",
          "AWS_ROLE_SESSION_NAME",
          "AWS_CONTAINER_CREDENTIALS_FULL_URI",
          "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI",
          "AWS_CONTAINER_AUTHORIZATION_TOKEN"
        ],
        do: {name, nil}
  end

  # What `tunnel` answers when the tunnel to ehos-`name`, in `dir`, is open on `port`.
  defp tunnel_open(dir, port, name \\ "trial", new? \\ true) do
    kubeconfig = Shell.word(Path.join(dir, "kubeconfig"))

    {:ok,
     %Report{
       outcome: "The tunnel to the API server of ehos-#{name} is open.",
       values: [{"Address", "127.0.0.1:#{port}"}, {"Context", "ehos-#{name}"}],
       next: [
         "kubectl --kubeconfig #{kubeconfig} --context ehos-#{name} get nodes",
         "mix ehos.server tunnel --close"
       ],
       secrets: [
         %Secret{kind: :shared_ssh_key, place: Process.get(:ssh_key)},
         %Secret{kind: :k3s_kubeconfig, place: Path.join(dir, "kubeconfig"), new?: new?}
       ],
       warnings: [k3s_kubeconfig_warning(name), @no_administrator_warning]
     }}
  end

  # What `tunnel` says when the key this workstation logs in with is on no person's line, and it
  # copies k3s's admin file.
  defp k3s_kubeconfig_warning(_name),
    do:
      {"The kubeconfig holds the certificate of k3s that each installation administrator shares.",
       "To get a certificate of your own, ask an installation administrator to add you with " <>
         "`admin add`. Then run `mix ehos.server tunnel --ssh-key PRIVATE_KEY` with the private " <>
         "key of the key that you gave."}

  # OpenTofu's runs, each with its environment, that refresh the server in `dir` on Oracle and
  # read its address.
  defp refreshed(dir) do
    env = tofu_env(dir)

    [
      {:tofu, tofu_init(dir), env},
      {:tofu, tofu_refresh(dir, "oci", "oci_core_instance.server"), env},
      {:tofu, tofu_output(), env}
    ]
  end

  # The tunnel opened in the background to the server in `dir`, forwarding `port`, as recorded.
  defp tunnel_opened(tmp_dir, dir, port) do
    {:tunnel, ~S(exec ssh "$@" </dev/null >"$0" 2>&1), "#{dir}/tunnel.log",
     ssh_options(Path.join(tmp_dir, "id_ed25519"), dir) ++
       [
         "-f",
         "-N",
         "-M",
         "-S",
         "#{dir}/tunnel.sock",
         "-o",
         "ExitOnForwardFailure=yes",
         "-L",
         "127.0.0.1:#{port}:127.0.0.1:6443",
         "ubuntu@#{@address}"
       ]}
  end

  # The kubeconfig k3s wrote, read over SSH, as recorded.
  defp kubeconfig_read(tmp_dir, dir),
    do: {:ssh, ssh_args(tmp_dir, dir, "sudo cat /etc/rancher/k3s/k3s.yaml 2>/dev/null")}

  # The read of the installation administrators, for the warnings `up` and `tunnel` give.
  defp administrators_read(tmp_dir, dir), do: {:ssh, ssh_args(tmp_dir, dir, @administrators_read)}

  # SSH's arguments to run `command` on the server, with the key in `tmp_dir`.
  defp ssh_args(tmp_dir, dir, command),
    do: ssh_options(Path.join(tmp_dir, "id_ed25519"), dir) ++ ["ubuntu@#{@address}", command]

  # A plan that updates the server, made on a state whose address was `before`, if any.
  defp plan_from(before) do
    prior = if before, do: %{"values" => %{"outputs" => %{"public_ip" => %{"value" => before}}}}

    ["update"]
    |> plan_json()
    |> Jason.decode!()
    |> Map.put("prior_state", prior)
    |> Jason.encode!()
  end

  # Nothing is run: neither a program nor OpenTofu.
  defp mock_nothing_run do
    expect(CommandRunnerMock, :run, 0, fn _program, _args -> {"", 0} end)
    expect(CommandRunnerMock, :run_env, 0, fn _program, _args, _env -> {"", 0} end)
  end

  # `value` inside a word a POSIX shell reads in single quotes: a `'` closes them, escapes itself
  # and opens them again.
  defp quoted(value), do: String.replace(value, "'", ~S('\''))

  # What `program` printed before it ended with exit status 1, as the error holds it, with `more`
  # added to what failed.
  defp failed(program, printed, more \\ ""),
    do:
      EhosPlatform.Failure.new(
        "`#{program}` failed with exit status 1." <> more,
        program,
        printed
      )
end
