defmodule Ehosctl.InstallTest do
  # Not async: capture_io(:stderr) captures stderr for every process.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Ehosctl.Config
  alias Ehosctl.FakeGitHub

  @moduletag :tmp_dir

  # In place of `EhosPlatform.Install`: answers what runs as the test puts it, and on an install
  # says what it was asked and writes what the real one leaves beside the installation.
  defmodule Platform do
    @moduledoc false

    def installed(opts) do
      send(self(), {:installed, opts})

      Process.get(
        {__MODULE__, :installed},
        {:ok, %{running: :none, digest: nil, host: nil, sign_in: nil, mail: nil, last: nil}}
      )
    end

    def server(opts) do
      send(self(), {:server, opts})
      dir = opts[:home] |> Path.expand() |> Path.join(opts[:name])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "install.json"), ~s({"host":"ehos.192-0-2-7.sslip.io"}))
      File.write!(Path.join(dir, "ca.crt"), Process.get({__MODULE__, :ca}))
      {:ok, "EHOS is running at https://ehos.192-0-2-7.sslip.io."}
    end
  end

  @image "ghcr.io/empoweredhouse/ehos@sha256:" <> String.duplicate("b", 64)
  @chart "oci://ghcr.io/empoweredhouse/charts/ehos@sha256:" <> String.duplicate("c", 64)

  setup %{tmp_dir: dir} do
    {github, github_opts} = FakeGitHub.start()
    %{cert: der} = :public_key.pkix_test_root_cert(~c"EHOS CA", [])
    Process.put({Platform, :ca}, :public_key.pem_encode([{:Certificate, der, :not_encrypted}]))

    opts =
      [
        install: Platform,
        home: Path.join(dir, "ehos"),
        config_dir: Path.join(dir, "config"),
        env: %{"GHCR_TOKEN" => "ghp_token"}
      ] ++ github_opts

    # The servers these tests install on: their state, as `ehosctl server up` leaves it.
    for name <- ~w(trial acme) do
      File.mkdir_p!(Path.join(opts[:home], name))
      File.write!(Path.join([opts[:home], name, "server.tfvars.json"]), "{}")
    end

    FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [release("0.6.0"), release("0.5.0")])
    %{github: github, opts: opts}
  end

  defp release(version, fields \\ %{}) do
    described =
      Map.merge(
        %{
          "schema" => "ehos.release/v1",
          "component" => "ehos",
          "version" => version,
          "image" => @image,
          "chart" => @chart
        },
        fields
      )

    {"v#{version}", %{"assets" => %{"release.json" => described}}}
  end

  defp ehosctl(argv, opts) do
    {code, stderr} =
      with_io(:stderr, fn ->
        stdout = capture_io(fn -> send(self(), {:code, Ehosctl.CLI.main(argv, opts)}) end)
        send(self(), {:stdout, stdout})
      end)
      |> then(fn {_, stderr} -> {receive(do: ({:code, code} -> code)), stderr} end)

    {code, receive(do: ({:stdout, stdout} -> stdout)), stderr}
  end

  test "installs the newest release by its digests, records it, and keeps the installation for login",
       %{opts: opts} do
    {0, stdout, ""} = ehosctl(~w(install --installation acme), opts)
    assert stdout =~ "EHOS is running at https://ehos.192-0-2-7.sslip.io."
    assert stdout =~ "Sign in with `ehosctl login --installation acme`"

    assert_received {:installed, installed}
    assert installed[:name] == "acme" and installed[:server_command] == "ehosctl server"

    assert_received {:server, server}
    assert server[:source] == %EhosPlatform.Source{chart: {:oci, @chart}, modules: nil}
    assert server[:digest] == "sha256:" <> String.duplicate("b", 64)
    assert server[:installed] == %{"version" => "0.6.0", "image" => @image, "chart" => @chart}
    assert server[:runner] == Ehosctl.PlatformRunner
    assert server[:token] == "ghp_token"

    {:ok, config} = Config.read(opts[:config_dir])
    assert config.current == nil

    assert config.installations["acme"] == %{
             "url" => "https://ehos.192-0-2-7.sslip.io",
             "ca" => Process.get({Platform, :ca})
           }
  end

  test "installs the release --version names, and refuses one EHOS does not have", %{opts: opts} do
    {0, _stdout, ""} = ehosctl(~w(install --version 0.5.0), opts)
    assert_received {:server, server}
    assert server[:installed]["version"] == "0.5.0" and server[:name] == "trial"

    {2, "", stderr} = ehosctl(~w(install --version 0.4.0), opts)
    assert stderr =~ "EHOS has no release 0.4.0"
  end

  defp runs(running, last \\ nil),
    do:
      Process.put(
        {Platform, :installed},
        {:ok, %{running: running, digest: nil, host: nil, sign_in: nil, mail: nil, last: last}}
      )

  test "installs the version that runs again, and refuses another, or other digests", %{
    opts: opts
  } do
    running = %{"version" => "0.6.0", "image" => @image, "chart" => @chart}
    runs(running)
    {0, _stdout, ""} = ehosctl(~w(install), opts)
    assert_received {:server, _server}

    runs(%{running | "version" => "0.5.0"})
    {2, "", stderr} = ehosctl(~w(install), opts)
    assert stderr =~ "trial runs EHOS 0.5.0; moving it to 0.6.0 is not an install"
    assert stderr =~ "`ehosctl upgrade --installation trial --to 0.6.0` does it"
    refute_received {:server, _server}

    other = "ghcr.io/empoweredhouse/ehos@sha256:" <> String.duplicate("d", 64)
    runs(%{running | "image" => other})
    {1, "", stderr} = ehosctl(~w(install), opts)
    assert stderr =~ "trial runs EHOS 0.6.0 as #{other}"
    assert stderr =~ "but its release now names #{@image}"
    refute_received {:server, _server}
  end

  test "refuses an installation whose version nothing recorded, naming upgrade", %{opts: opts} do
    runs(:unknown)
    {2, "", stderr} = ehosctl(~w(install), opts)
    assert stderr =~ "whose version ehosctl cannot read from the cluster, as `mix ehos.install`"
    assert stderr =~ "`ehosctl upgrade --installation trial` moves it"
    refute_received {:server, _server}
  end

  test "installs after a first attempt that failed, and says so; refuses under one pending", %{
    opts: opts
  } do
    runs(:none, %{revision: 1, status: "failed", description: "context deadline exceeded"})
    {0, stdout, ""} = ehosctl(~w(install), opts)

    assert stdout =~
             "The last attempt, Helm's revision 1, had failed (context deadline exceeded)."

    assert stdout =~ "EHOS is running"
    assert_received {:server, _server}

    runs(%{"version" => "0.6.0", "image" => @image, "chart" => @chart}, %{
      revision: 4,
      status: "pending-upgrade",
      description: "Preparing upgrade"
    })

    {1, "", stderr} = ehosctl(~w(install --installation acme), opts)
    assert stderr =~ "Helm's revision 4, is pending-upgrade (Preparing upgrade)"
    kubeconfig = Path.join([opts[:home], "acme", "kubeconfig"])
    helm = "helm --kubeconfig #{kubeconfig} --kube-context ehos-acme -n ehos-system"
    assert stderr =~ "`#{helm} history ehos`"
    assert stderr =~ "`#{helm} rollback ehos <the last deployed revision>`"
    refute_received {:server, _server}

    # A first install interrupted has nothing to roll back to.
    runs(:none, %{revision: 1, status: "pending-install", description: "Initial install underway"})

    {1, "", stderr} = ehosctl(~w(install --installation acme), opts)
    assert stderr =~ "`#{helm} uninstall ehos` removes it, since nothing ran before it"
    refute stderr =~ "rollback"
  end

  test "installs over a release that was uninstalled, as Helm does", %{opts: opts} do
    runs(:none, %{revision: 3, status: "uninstalled", description: "Uninstallation complete"})
    {0, stdout, ""} = ehosctl(~w(install), opts)
    assert stdout =~ "EHOS is running"
    assert_received {:server, _server}
  end

  test "keeps the console's host EHOS serves when installed again, unless --host names another",
       %{opts: opts} do
    running = %{"version" => "0.6.0", "image" => @image, "chart" => @chart}

    Process.put(
      {Platform, :installed},
      {:ok,
       %{
         running: running,
         digest: nil,
         host: "ehos.acme.example.org",
         sign_in: nil,
         mail: nil,
         last: nil
       }}
    )

    {0, _stdout, ""} = ehosctl(~w(install), opts)
    assert_received {:server, server}
    assert server[:host] == "ehos.acme.example.org"

    {0, _stdout, ""} = ehosctl(~w(install --host ehos.other.example.org), opts)
    assert_received {:server, server}
    assert server[:host] == "ehos.other.example.org"
  end

  test "refuses a release that names no image and chart by digest", %{github: github, opts: opts} do
    FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [
      release("0.6.0", %{"image" => "ghcr.io/empoweredhouse/ehos:latest"}),
      release("0.5.0", %{
        "chart" => "oci://elsewhere.example/ehos@sha256:" <> String.duplicate("c", 64)
      })
    ])

    for argv <- [~w(install), ~w(install --version 0.5.0)] do
      {1, "", stderr} = ehosctl(argv, opts)
      assert stderr =~ "names no image and chart of EHOS's by digest"
    end

    refute_received {:server, _server}
  end

  test "says what stops it before it asks GitHub, as an unopened tunnel", %{
    github: github,
    opts: opts
  } do
    Bypass.down(github)

    Process.put(
      {Platform, :installed},
      {:error, "…/kubeconfig is missing. Open the tunnel first: `ehosctl server tunnel`"}
    )

    {1, "", stderr} = ehosctl(~w(install), opts)
    assert stderr =~ "Open the tunnel first: `ehosctl server tunnel`"
  end

  test "takes the installation of that name to the new address, without its old sign-in", %{
    opts: opts
  } do
    :ok =
      Config.write(
        %Config{
          current: "acme",
          installations: %{
            "acme" => %{"url" => "https://ehos.old.example.com", "sign_in" => %{"subject" => "s"}}
          }
        },
        opts[:config_dir]
      )

    {0, stdout, ""} = ehosctl(~w(install --installation acme), opts)
    assert stdout =~ "The installation acme was at https://ehos.old.example.com; it is"

    # Installed again at the same address, it says nothing of it.
    {0, stdout, ""} = ehosctl(~w(install --installation acme), opts)
    refute stdout =~ "was at"
    {:ok, config} = Config.read(opts[:config_dir])
    assert config.current == "acme"
    assert config.installations["acme"]["url"] == "https://ehos.192-0-2-7.sslip.io"
    refute Map.has_key?(config.installations["acme"], "sign_in")
  end

  test "says how to sign in when the installation cannot be kept", %{opts: opts, tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "config"))
    File.write!(Path.join([dir, "config", "config.json"]), "{not json")

    {0, stdout, ""} = ehosctl(~w(install --installation acme), opts)
    assert stdout =~ "EHOS is running"
    assert stdout =~ "EHOSCTL_CA_FILE=#{Path.join([dir, "ehos", "acme", "ca.crt"])}"
    assert stdout =~ "--installation acme https://ehos.192-0-2-7.sslip.io`"
  end

  # eh-os D-36, ehos-tools#298: the SMTP server EHOS sends mail through, so invitations arrive by
  # email.
  describe "the SMTP server" do
    @smtp ~w(--smtp-host smtp.example.com --smtp-username ehos --mail-from ehos@example.com)
    @mail %{
      "from" => "ehos@example.com",
      "smtp" => %{"host" => "smtp.example.com", "port" => 587, "username" => "ehos"}
    }

    defp running_with(mail) do
      running = %{"version" => "0.6.0", "image" => @image, "chart" => @chart}

      Process.put(
        {Platform, :installed},
        {:ok, %{running: running, digest: nil, host: nil, sign_in: nil, mail: mail, last: nil}}
      )
    end

    test "is given to the platform with the password from SMTP_PASSWORD alone", %{opts: opts} do
      opts = Keyword.update!(opts, :env, &Map.put(&1, "SMTP_PASSWORD", "pw"))
      {0, _stdout, ""} = ehosctl(["install" | @smtp], opts)
      assert_received {:server, server}
      assert server[:mail] == @mail
      assert server[:smtp_password] == "pw"

      {0, _stdout, ""} =
        ehosctl(
          ~w(install --smtp-host mail.example.com --smtp-port 465 --mail-from a@example.com),
          opts
        )

      assert_received {:server, server}

      assert server[:mail] == %{
               "from" => "a@example.com",
               "smtp" => %{"host" => "mail.example.com", "port" => 465}
             }
    end

    test "sends none when nothing names one", %{opts: opts} do
      {0, _stdout, ""} = ehosctl(~w(install), opts)
      assert_received {:server, server}
      assert server[:mail] == nil
      assert server[:smtp_password] == nil
    end

    test "keeps the one EHOS runs with, given options over it, until --no-mail", %{opts: opts} do
      running_with(@mail)

      {0, _stdout, ""} = ehosctl(~w(install), opts)
      assert_received {:server, server}
      assert server[:mail] == @mail

      {0, _stdout, ""} = ehosctl(["install", "--smtp-port", "465", "--smtp-username", ""], opts)
      assert_received {:server, server}

      assert server[:mail] == %{
               "from" => "ehos@example.com",
               "smtp" => %{"host" => "smtp.example.com", "port" => 465}
             }

      {0, _stdout, ""} = ehosctl(~w(install --no-mail), opts)
      assert_received {:server, server}
      assert server[:mail] == nil
    end

    test "is refused before anything changes when it is not whole or not what the chart takes",
         %{opts: opts} do
      for {argv, message} <- [
            {~w(--smtp-host smtp.example.com), "--smtp-host needs --mail-from"},
            {~w(--mail-from a@example.com), "--mail-from needs --smtp-host"},
            {~w(--smtp-port 2525 --smtp-username u),
             "--smtp-port, --smtp-username need --smtp-host"},
            {@smtp ++ ~w(--smtp-port 70000), "--smtp-port must be a port, 1 to 65535"},
            {~w(--smtp-host smtp.example.com --mail-from nobody),
             "--mail-from must be an email address"},
            {~w(--smtp-host bad_host! --mail-from a@example.com),
             "--smtp-host must be a DNS name"},
            {["--smtp-host", "h.example.com", "--mail-from", "a@example.com\r\nBcc: x@y.com"],
             "--mail-from must be an email address"},
            {@smtp ++ ~w(--no-mail), "--no-mail stops EHOS sending mail: leave out"}
          ] do
        {2, "", stderr} = ehosctl(["install" | argv], opts)
        assert stderr =~ message
        refute_received {:server, _server}
      end
    end

    test "refuses a given value that does not fit, and adds a user to the one EHOS runs with",
         %{opts: opts} do
      running_with(%{"from" => "ehos@example.com", "smtp" => %{"host" => "h", "port" => 587}})
      {2, "", stderr} = ehosctl(~w(install --mail-from bad), opts)
      assert stderr =~ "--mail-from must be an email address"

      running_with(%{"from" => "ehos@example.com", "smtp" => %{"host" => "h", "port" => 587}})
      opts = Keyword.update!(opts, :env, &Map.put(&1, "SMTP_PASSWORD", "pw"))
      {0, _stdout, ""} = ehosctl(~w(install --smtp-username ehos), opts)
      assert_received {:server, server}
      assert server[:mail]["smtp"]["username"] == "ehos"
    end

    # The password the cluster holds was given for one server and user: EHOS would otherwise send
    # it to another.
    test "asks for SMTP_PASSWORD where the host or the user is not the one it was given for",
         %{opts: opts} do
      for argv <- [~w(--smtp-host other.example.com), ~w(--smtp-username bob)] do
        running_with(@mail)
        {2, "", stderr} = ehosctl(["install" | argv], opts)
        assert stderr =~ "SMTP_PASSWORD must give the password of"
        assert stderr =~ "was given for ehos at smtp.example.com"
        refute_received {:server, _server}

        running_with(@mail)
        with_password = Keyword.update!(opts, :env, &Map.put(&1, "SMTP_PASSWORD", "pw"))
        {0, _stdout, ""} = ehosctl(["install" | argv], with_password)
        assert_received {:server, server}
        assert server[:smtp_password] == "pw"
      end

      running_with(nil)
      {2, "", stderr} = ehosctl(["install" | @smtp], opts)
      assert stderr =~ "was given for no user EHOS runs with"

      # A DNS name is the same whatever its case.
      running_with(@mail)
      {0, _stdout, ""} = ehosctl(~w(install --smtp-host SMTP.Example.com --smtp-port 465), opts)
      assert_received {:server, _server}
    end

    # Settings someone set with Helm by hand: never turned off without a word.
    test "refuses to keep settings it did not write, unless replaced or stopped", %{opts: opts} do
      running_with(:unreadable)
      {2, "", stderr} = ehosctl(~w(install), opts)
      assert stderr =~ "EHOS here sends mail through settings ehosctl did not write"
      refute_received {:server, _server}

      running_with(:unreadable)
      {2, "", stderr} = ehosctl(~w(install --smtp-port 465), opts)
      assert stderr =~ "settings ehosctl did not write"

      running_with(:unreadable)

      {0, _stdout, ""} =
        ehosctl(~w(install --smtp-host h.example.com --mail-from a@example.com), opts)

      assert_received {:server, server}

      assert server[:mail] == %{
               "from" => "a@example.com",
               "smtp" => %{"host" => "h.example.com", "port" => 587}
             }

      running_with(:unreadable)
      {0, _stdout, ""} = ehosctl(~w(install --no-mail), opts)
      assert_received {:server, server}
      assert server[:mail] == nil
    end

    test "refuses a password with no server to give it to, unless --no-mail", %{opts: opts} do
      opts = Keyword.update!(opts, :env, &Map.put(&1, "SMTP_PASSWORD", "leftover"))
      {2, "", stderr} = ehosctl(~w(install), opts)
      assert stderr =~ "SMTP_PASSWORD is set, but no SMTP server is"
      refute_received {:server, _server}
    end

    test "sends no password left in the shell where it sends no mail", %{opts: opts} do
      running_with(@mail)
      opts = Keyword.update!(opts, :env, &Map.put(&1, "SMTP_PASSWORD", "leftover"))
      {0, _stdout, ""} = ehosctl(~w(install --no-mail), opts)
      assert_received {:server, server}
      assert server[:mail] == nil
      assert server[:smtp_password] == nil
    end
  end

  # eh-os D-113: how long a sign-in to an application lasts, given to the chart of an EHOS that
  # takes it.
  describe "the sign-in limits" do
    setup %{github: github} do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [release("0.10.0"), release("0.6.0")])
      :ok
    end

    test "are given to the platform, and those EHOS runs with are kept", %{opts: opts} do
      {0, _stdout, ""} = ehosctl(~w(install --sign-in-absolute 30d --sign-in-idle 14d), opts)
      assert_received {:server, server}
      assert server[:sign_in] == %{"absolute" => "30d", "idle" => "14d"}

      {0, _stdout, ""} = ehosctl(~w(install), opts)
      assert_received {:server, server}
      assert server[:sign_in] == nil

      running = %{"version" => "0.10.0", "image" => @image, "chart" => @chart}

      Process.put(
        {Platform, :installed},
        {:ok,
         %{
           running: running,
           digest: nil,
           host: nil,
           sign_in: %{"absolute" => "30d"},
           mail: nil,
           last: nil
         }}
      )

      {0, _stdout, ""} = ehosctl(~w(install --sign-in-idle 7d), opts)
      assert_received {:server, server}
      assert server[:sign_in] == %{"absolute" => "30d", "idle" => "7d"}
    end

    test "take the bounds the chart takes", %{opts: opts} do
      for argv <- [~w(--sign-in-absolute 366d), ~w(--sign-in-absolute 2d --sign-in-idle 48h)] do
        {0, _stdout, ""} = ehosctl(["install" | argv], opts)
        assert_received {:server, _server}
      end
    end

    test "are refused as the chart would refuse them, before anything changes", %{opts: opts} do
      for {argv, message} <- [
            {~w(--sign-in-absolute 30m),
             ~s(--sign-in-absolute must be whole hours or days, such as 12h or 30d, not "30m")},
            {~w(--sign-in-idle 0d), ~s(--sign-in-idle must be whole hours or days)},
            {~w(--sign-in-absolute 367d), "--sign-in-absolute (367d) must be at most 366d"},
            {~w(--sign-in-idle 13h),
             "--sign-in-idle (13h) must be at most the default absolute limit (12h)"}
          ] do
        {2, "", stderr} = ehosctl(["install" | argv], opts)
        assert stderr =~ message
        refute_received {:server, _server}
      end
    end

    test "name the value EHOS runs with when it is the one that does not fit", %{opts: opts} do
      running = %{"version" => "0.10.0", "image" => @image, "chart" => @chart}
      limits = %{"absolute" => "30d", "idle" => "14d"}

      Process.put(
        {Platform, :installed},
        {:ok, %{running: running, digest: nil, host: nil, sign_in: limits, mail: nil, last: nil}}
      )

      {2, "", stderr} = ehosctl(~w(install --sign-in-absolute 7d), opts)

      assert stderr =~
               "the idle limit EHOS runs with (14d) must be at most --sign-in-absolute (7d)"
    end

    test "are refused for an EHOS before 0.10.0, which has none to set", %{opts: opts} do
      {2, "", stderr} = ehosctl(~w(install --version 0.6.0 --sign-in-absolute 30d), opts)
      assert stderr =~ "EHOS 0.6.0 has no sign-in limits to set"
      refute_received {:server, _server}
    end
  end

  test "gives the platform --host and GHCR_USERNAME", %{opts: opts} do
    opts = Keyword.update!(opts, :env, &Map.put(&1, "GHCR_USERNAME", "octocat"))
    {0, _stdout, ""} = ehosctl(~w(install --host ehos.acme.example.org), opts)
    assert_received {:server, server}
    assert server[:host] == "ehos.acme.example.org" and server[:username] == "octocat"
  end

  test "has the platform name the installation in every command it suggests", %{opts: opts} do
    {0, _stdout, ""} = ehosctl(~w(install), opts)
    assert_received {:installed, installed}
    assert_received {:server, server}

    for given <- [installed, server] do
      assert given[:server_command] == "ehosctl server"
      assert given[:name_option] == "--installation" and given[:name_in_commands] == true
    end
  end

  test "says when EHOS has no release, or one with no release.json", %{
    github: github,
    opts: opts
  } do
    FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [{"v0.4.0", %{"assets" => %{}}}])
    {1, "", stderr} = ehosctl(~w(install), opts)
    assert stderr =~ "v0.4.0 names no image and chart of EHOS's by digest"

    FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [])
    {1, "", stderr} = ehosctl(~w(install), opts)
    assert stderr =~ "EHOS has no release yet."
  end

  test "prints a failing tool's output with what a terminal would act on escaped", %{
    opts: opts
  } do
    # A revision's description is the cluster's text, and helm prints it (#165).
    Process.put(
      {Platform, :installed},
      {:error, "`helm` failed with exit status 1:\nError: \e]52;c;cGF3bmVk\a\e[2Jrevision 3"}
    )

    {1, "", stderr} = ehosctl(~w(install), opts)
    assert stderr =~ "ehosctl: `helm` failed with exit status 1:\n"
    assert stderr =~ ~S("Error: \u{1B}]52;c;cGF3bmVk\u{7}\u{1B}[2Jrevision 3")
    refute stderr =~ "\e"
  end

  # A server made before Stage 13 is under `trial`, while the current installation is named after
  # its host (#194).
  test "refuses an installation no server is known under, naming those that are, before " <>
         "anything runs",
       %{opts: opts} do
    :ok =
      Ehosctl.Config.write(
        %Ehosctl.Config{
          current: "ehos-92-5-148-138",
          installations: %{"ehos-92-5-148-138" => %{"url" => "https://ehos.192-0-2-7.sslip.io"}}
        },
        opts[:config_dir]
      )

    {2, "", stderr} = ehosctl(~w(install), opts)

    assert stderr =~
             "No server is known under ehos-92-5-148-138 (the current installation); servers " <>
               "on this machine: acme, trial. Run the command again with --installation and " <>
               "one of them."

    refute_received {:installed, _opts}
  end

  test "says in its help that it is on the platform plane", %{opts: opts} do
    {0, help, ""} = ehosctl(~w(install --help), opts)
    assert help =~ "Plane: platform."
  end
end
