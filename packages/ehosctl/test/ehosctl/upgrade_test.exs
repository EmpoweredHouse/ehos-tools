defmodule Ehosctl.UpgradeTest do
  # Not async: capture_io(:stderr) captures stderr for every process.
  use Ehosctl.Case, async: false

  @env %{"GHCR_TOKEN" => "ghp_token", "EHOS_STATE_PASSPHRASE" => "a passphrase of 16+"}

  import ExUnit.CaptureIO

  alias Ehosctl.FakeGitHub

  @moduletag :tmp_dir

  # In place of `EhosPlatform.Install`: answers what runs as the test puts it, and on an install
  # says what it was asked and writes what the real one leaves beside the installation.
  defmodule Platform do
    @moduledoc false

    def installed(opts) do
      send(self(), {:installed, opts})
      Process.get({__MODULE__, :installed})
    end

    def server(opts) do
      send(self(), {:server, opts})
      dir = opts[:home] |> Path.expand() |> Path.join(opts[:name])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "install.json"), ~s({"host":"ehos.acme.example.org"}))
      File.write!(Path.join(dir, "ca.crt"), Process.get({__MODULE__, :ca}))
      {:ok, "EHOS is running at https://ehos.acme.example.org."}
    end
  end

  @host "ehos.acme.example.org"

  setup %{tmp_dir: dir} do
    {github, github_opts} = FakeGitHub.start()
    %{cert: der} = :public_key.pkix_test_root_cert(~c"EHOS CA", [])
    Process.put({Platform, :ca}, :public_key.pem_encode([{:Certificate, der, :not_encrypted}]))
    test_pid = self()
    stub_env(@env)

    opts =
      [
        install: Platform,
        home: Path.join(dir, "ehos"),
        config_dir: Path.join(dir, "config")
      ] ++ github_opts

    # The person answers the question with what `:answer` holds, no unless a test says.
    stub(Ehosctl.TerminalMock, :gets, fn question ->
      send(test_pid, {:asked, question})
      if Process.get(:answer, false), do: "y\n", else: "n\n"
    end)

    # The servers these tests upgrade: their state, as `ehosctl server up` leaves it.
    for name <- ~w(trial acme) do
      File.mkdir_p!(Path.join(opts[:home], name))
      File.write!(Path.join([opts[:home], name, "server.tfvars.json"]), "{}")
      File.write!(Path.join([opts[:home], name, "installation.json"]), ~s({"provider": "oci"}))
    end

    FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [
      release("0.7.0", %{"migrates" => false}),
      release("0.6.0", %{"migrates" => true}),
      release("0.5.0", %{"migrates" => true})
    ])

    runs(recorded("0.5.0"))
    %{github: github, opts: opts}
  end

  defp image(version), do: "ghcr.io/empoweredhouse/ehos@" <> digest(version)
  defp digest(version), do: "sha256:" <> String.duplicate(hex(version), 64)
  defp hex("0.7.0"), do: "7"
  defp hex("0.6.0"), do: "6"
  defp hex("0.5.0"), do: "5"
  defp hex(_other), do: "0"

  defp chart(version),
    do: "oci://ghcr.io/empoweredhouse/charts/ehos@sha256:" <> String.duplicate(hex(version), 64)

  defp release(version, fields) do
    described =
      Map.merge(
        %{
          "schema" => "ehos.release/v1",
          "component" => "ehos",
          "version" => version,
          "image" => image(version),
          "chart" => chart(version)
        },
        fields
      )

    {"v#{version}",
     %{"assets" => %{"release.json" => described}, "body" => "What #{version} changed."}}
  end

  defp recorded(version),
    do: %{"version" => version, "image" => image(version), "chart" => chart(version)}

  defp runs(running, fields \\ %{}),
    do:
      Process.put(
        {Platform, :installed},
        {:ok,
         Map.merge(
           %{
             running: running,
             digest: nil,
             host: @host,
             sign_in: nil,
             four_eyes: nil,
             four_eyes_runs: nil,
             mail: nil,
             last: nil
           },
           fields
         )}
      )

  defp ehosctl(argv, opts) do
    {code, stderr} =
      with_io(:stderr, fn ->
        stdout = capture_io(fn -> send(self(), {:code, Ehosctl.CLI.main(argv, opts)}) end)
        send(self(), {:stdout, stdout})
      end)
      |> then(fn {_, stderr} -> {receive(do: ({:code, code} -> code)), stderr} end)

    stdout = receive(do: ({:stdout, stdout} -> stdout))
    send(self(), {:printed, stdout})
    {code, stdout, stderr}
  end

  defp installed_version do
    assert_received {:server, server}
    server[:installed]["version"]
  end

  # The question and the install, in the order they came.
  defp said do
    {:messages, messages} = Process.info(self(), :messages)
    for {tag, _} = message <- messages, tag in [:asked, :server], do: message
  end

  # Asks on stderr too, so a test sees where the question came among the warnings.
  defp mock_asked_on_stderr do
    test_pid = self()

    stub(Ehosctl.TerminalMock, :gets, fn question ->
      send(test_pid, {:asked, question})
      IO.write(:stderr, "[asked]\n")
      "y\n"
    end)
  end

  # What every run printed on stdout, in order.
  defp printed do
    receive do
      {:printed, stdout} -> stdout <> printed()
    after
      0 -> ""
    end
  end

  # eh-os D-141: the person answers knowing that a relay without a user admits every application.
  test "warns of an SMTP server with no user before it asks", %{opts: opts} do
    no_user = %{
      "from" => "ehos@example.com",
      "smtp" => %{"host" => "smtp.example.com", "port" => 587}
    }

    runs(recorded("0.5.0"), %{mail: no_user})
    mock_asked_on_stderr()

    {0, _stdout, stderr} = ehosctl(~w(upgrade), opts)

    warning = "==> Warning: EHOS sends mail through smtp.example.com:587 with no SMTP user."
    assert String.starts_with?(stderr, warning)
    assert String.ends_with?(stderr, "[asked]\n")

    assert [{:asked, _question}, {:server, server}] = said()

    assert server[:mail] == no_user
  end

  test "moves to the newest release after the notes on the way, asking first since one migrates",
       %{opts: opts} do
    Process.put(:answer, true)
    {0, stdout, ""} = ehosctl(~w(upgrade --installation acme), opts)
    assert stdout =~ "EHOS is running at https://ehos.acme.example.org."
    assert stdout =~ "Sign in with `ehosctl login --installation acme`"

    printed = printed()
    assert printed =~ "acme runs EHOS 0.5.0; moving it to 0.7.0."
    assert printed =~ "Its console stays at https://ehos.acme.example.org."
    # Newest first, the releases after 0.5.0 up to 0.7.0, and not 0.5.0 itself.
    assert printed =~ ~r/# ehos 0\.7\.0 .*What 0\.7\.0 changed\..*# ehos 0\.6\.0 .*What 0\.6\.0/s
    refute printed =~ "What 0.5.0 changed."

    assert_received {:asked, question}
    assert question =~ "EHOS 0.6.0 changes the governance database"
    assert question =~ "keeps no backup"

    assert_received {:installed, installed}
    assert installed[:name] == "acme" and installed[:server_command] == "ehosctl server"

    assert_received {:server, server}
    assert server[:source] == %EhosPlatform.Source{chart: {:oci, chart("0.7.0")}, modules: nil}
    assert server[:digest] == digest("0.7.0")
    assert server[:installed] == recorded("0.7.0")
    # The console stays where it is.
    assert server[:host] == @host
    assert server[:token] == "ghp_token"
    assert server[:runner] == Ehosctl.PlatformRunner
    # eh-os#823: the switch, for a server running k3s's Traefik, only when asked.
    assert server[:passphrase] == "a passphrase of 16+"
    assert server[:switch_traefik] == false
  end

  # eh-os#823: a server running k3s's Traefik is switched only when asked, with the key given.
  test "passes --switch-traefik and --ssh-key to the install", %{opts: opts} do
    Process.put(:answer, true)

    {0, _stdout, ""} =
      ehosctl(~w(upgrade --installation acme --switch-traefik --ssh-key /keys/acme), opts)

    assert_received {:server, server}
    assert server[:switch_traefik] == true
    assert server[:ssh_key] == "/keys/acme"
  end

  # eh-os D-113: the limits it was installed with stay, unless the options give others.
  describe "the sign-in limits" do
    setup %{github: github} do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [
        release("0.10.0", %{"migrates" => false}),
        release("0.7.0", %{"migrates" => false})
      ])

      :ok
    end

    test "are kept, and others the options give are taken", %{opts: opts} do
      runs(recorded("0.7.0"), %{sign_in: %{"absolute" => "30d", "idle" => "14d"}})
      {0, _stdout, ""} = ehosctl(~w(upgrade), opts)
      assert_received {:server, server}
      assert server[:sign_in] == %{"absolute" => "30d", "idle" => "14d"}
      assert printed() =~ "A sign-in to an application lasts 30d, 14d unused."

      runs(recorded("0.7.0"), %{sign_in: %{"absolute" => "30d", "idle" => "14d"}})
      {0, _stdout, ""} = ehosctl(~w(upgrade --sign-in-idle 2d), opts)
      assert_received {:server, server}
      assert server[:sign_in] == %{"absolute" => "30d", "idle" => "2d"}
      assert printed() =~ "A sign-in to an application lasts 30d, 2d unused."

      runs(recorded("0.7.0"))
      {0, _stdout, ""} = ehosctl(~w(upgrade), opts)
      assert_received {:server, server}
      assert server[:sign_in] == nil
      refute printed() =~ "A sign-in to an application lasts"
    end

    test "are refused as the chart would refuse them, before anything changes", %{opts: opts} do
      runs(recorded("0.7.0"), %{sign_in: %{"absolute" => "30d"}})
      {2, "", stderr} = ehosctl(~w(upgrade --sign-in-idle 31d), opts)

      assert stderr =~
               "--sign-in-idle (31d) must be at most the absolute limit EHOS runs with (30d)"

      refute_received {:server, _server}
    end

    test "given to the version that runs, are named in the command that installs them",
         %{opts: opts} do
      runs(recorded("0.10.0"))
      {0, stdout, ""} = ehosctl(~w(upgrade --sign-in-absolute 30d --sign-in-idle 14d), opts)
      assert stdout =~ "so the sign-in limits were not applied either"
      assert stdout =~ "--version 0.10.0 --sign-in-absolute 30d --sign-in-idle 14d`"
      refute_received {:server, _server}
    end

    test "are not sent to an EHOS before 0.10.0, and not said", %{opts: opts} do
      runs(recorded("0.10.0"), %{sign_in: %{"absolute" => "30d"}})
      {0, _stdout, ""} = ehosctl(~w(upgrade --to 0.7.0 --allow-downgrade --yes), opts)
      assert_received {:server, server}
      assert server[:sign_in] == nil
      refute printed() =~ "A sign-in to an application lasts"
    end
  end

  # eh-os D-124: the console's host of sslip.io would name the server's old address.
  test "is refused while the console's host names the server's old address, and --host moves it",
       %{opts: opts, github: github} do
    FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [
      release("0.10.0", %{"migrates" => false}),
      release("0.9.0", %{"migrates" => false})
    ])

    runs(recorded("0.9.0"), %{host: "ehos.192-0-2-1.sslip.io"})
    File.write!(Path.join([opts[:home], "trial", "tunnel.json"]), ~s({"address": "198.51.100.9"}))
    {2, "", stderr} = ehosctl(~w(upgrade --yes), opts)
    assert stderr =~ "give --host ehos.198-51-100-9.sslip.io"
    refute_received {:server, _server}

    # `upgrade` moves the host itself, which an EHOS whose version nothing recorded needs: `install`
    # refuses it.
    {0, _stdout, ""} = ehosctl(~w(upgrade --yes --host ehos.198-51-100-9.sslip.io), opts)
    assert_received {:server, server}
    assert server[:host] == "ehos.198-51-100-9.sslip.io"
  end

  # eh-os D-105, ehos-tools#296: four eyes turned off stay off, unless --four-eyes says otherwise.
  describe "four eyes" do
    setup %{github: github} do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [
        release("0.10.0", %{"migrates" => false}),
        release("0.9.0", %{"migrates" => false}),
        release("0.8.0", %{"migrates" => false})
      ])

      :ok
    end

    test "are kept and said when off, and the flags change them", %{opts: opts} do
      runs(recorded("0.9.0"), %{four_eyes: false})
      {0, _stdout, ""} = ehosctl(~w(upgrade --yes), opts)
      assert_received {:server, server}
      assert server[:four_eyes] == false
      assert printed() =~ "Whoever deployed or asked for a promotion may approve it"

      runs(recorded("0.9.0"), %{four_eyes: false})
      {0, _stdout, ""} = ehosctl(~w(upgrade --four-eyes --yes), opts)
      assert_received {:server, server}
      assert server[:four_eyes] == true
      refute printed() =~ "may approve it"

      runs(recorded("0.9.0"))
      {0, _stdout, ""} = ehosctl(~w(upgrade --no-four-eyes --yes), opts)
      assert_received {:server, server}
      assert server[:four_eyes] == false
    end

    test "given to the version that runs, are named in the command that installs them",
         %{opts: opts} do
      runs(recorded("0.10.0"))
      {0, stdout, ""} = ehosctl(~w(upgrade --no-four-eyes --sign-in-absolute 30d), opts)
      assert stdout =~ "so the sign-in limits and the four-eyes setting were not applied either"
      assert stdout =~ "--version 0.10.0 --sign-in-absolute 30d --no-four-eyes`"
      refute_received {:server, _server}

      {0, stdout, ""} = ehosctl(~w(upgrade --no-four-eyes), opts)
      assert stdout =~ "so the four-eyes setting was not applied either"

      argv = ~w(upgrade --sign-in-idle 1h --four-eyes --smtp-host h.example.com --mail-from a@b.c)
      {0, stdout, ""} = ehosctl(argv, opts)

      assert stdout =~
               "so the sign-in limits, the four-eyes setting and the mail settings were not " <>
                 "applied either"
    end

    # eh-os D-128, #350: left to a chart that keeps what runs, they are as the server runs them.
    test "left to the chart, are said when off as the server runs them, where the chart keeps that",
         %{github: github, opts: opts} do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [
        release("0.14.0", %{"migrates" => false}),
        release("0.13.0", %{"migrates" => false}),
        release("0.12.0", %{"migrates" => false})
      ])

      runs(recorded("0.13.0"), %{four_eyes_runs: false})
      {0, _stdout, ""} = ehosctl(~w(upgrade --yes), opts)
      assert_received {:server, server}
      assert server[:four_eyes] == nil
      assert printed() =~ "Whoever deployed or asked for a promotion may approve it"

      runs(recorded("0.13.0"), %{four_eyes_runs: true})
      {0, _stdout, ""} = ehosctl(~w(upgrade --yes), opts)
      assert_received {:server, _server}
      refute printed() =~ "may approve it"

      # Not read, as on a server before 0.9.0 or a call that failed, it is not said.
      runs(recorded("0.13.0"))
      {0, _stdout, ""} = ehosctl(~w(upgrade --yes), opts)
      assert_received {:server, _server}
      refute printed() =~ "may approve it"

      # Turned on by the flag, whatever runs.
      runs(recorded("0.13.0"), %{four_eyes_runs: false})
      {0, _stdout, ""} = ehosctl(~w(upgrade --four-eyes --yes), opts)
      assert_received {:server, server}
      assert server[:four_eyes] == true
      refute printed() =~ "may approve it"

      # A chart before 0.14.0 turns them on when given nothing, whatever runs.
      runs(recorded("0.12.0"), %{four_eyes_runs: false})
      {0, _stdout, ""} = ehosctl(~w(upgrade --to 0.13.0 --yes), opts)
      assert_received {:server, _server}
      refute printed() =~ "may approve it"
    end

    test "are not sent to an EHOS before 0.9.0, and not said", %{opts: opts} do
      runs(recorded("0.9.0"), %{four_eyes: false})
      {0, _stdout, ""} = ehosctl(~w(upgrade --to 0.8.0 --allow-downgrade --yes), opts)
      assert_received {:server, server}
      assert server[:four_eyes] == nil
      refute printed() =~ "may approve it"
    end
  end

  # eh-os D-36, ehos-tools#298: kept as the sign-in limits are.
  describe "the SMTP server" do
    setup %{github: github} do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [
        release("0.10.0", %{"migrates" => false}),
        release("0.7.0", %{"migrates" => false})
      ])

      :ok
    end

    @mail %{
      "from" => "ehos@example.com",
      "smtp" => %{"host" => "smtp.example.com", "port" => 587, "username" => "ehos"}
    }

    test "is kept and said, and the options change it", %{opts: opts} do
      runs(recorded("0.7.0"), %{mail: @mail})
      {0, _stdout, ""} = ehosctl(~w(upgrade), opts)
      assert_received {:server, server}
      assert server[:mail] == @mail

      assert printed() =~
               "It sends mail from ehos@example.com through smtp.example.com:587 as ehos."

      runs(recorded("0.7.0"), %{mail: @mail})
      {0, _stdout, ""} = ehosctl(~w(upgrade --mail-from team@example.com), opts)
      assert_received {:server, server}
      assert server[:mail]["from"] == "team@example.com"

      runs(recorded("0.7.0"), %{mail: @mail})
      {0, _stdout, ""} = ehosctl(~w(upgrade --no-mail), opts)
      assert_received {:server, server}
      assert server[:mail] == nil
      assert printed() =~ "It sends no mail."
    end

    # eh-os D-141: a relay that admits the server by its address admits every application on it.
    test "without a user, is warned of, and the upgrade goes on",
         %{opts: opts} do
      no_user = %{
        "from" => "ehos@example.com",
        "smtp" => %{"host" => "smtp.example.com", "port" => 587}
      }

      runs(recorded("0.7.0"), %{mail: no_user})
      {0, _stdout, stderr} = ehosctl(~w(upgrade), opts)
      assert_received {:server, server}
      assert server[:mail] == no_user

      assert stderr =~
               "==> Warning: EHOS sends mail through smtp.example.com:587 with no SMTP user. A " <>
                 "relay that admits the server by its address admits every application on it"

      # With a user, nothing is said.
      runs(recorded("0.7.0"), %{mail: @mail})
      {0, _stdout, ""} = ehosctl(~w(upgrade), opts)
      assert_received {:server, _server}
    end

    # A user EHOS runs with, cleared by `--smtp-username ""`: the warning comes through progress,
    # before the install, and the user is gone.
    test "with its kept user cleared, is warned of, and installed without one", %{opts: opts} do
      runs(recorded("0.7.0"), %{mail: @mail})

      {0, _stdout, stderr} = ehosctl(["upgrade", "--smtp-username", ""], opts)

      assert stderr =~
               "==> Warning: EHOS sends mail through smtp.example.com:587 with no SMTP user."

      assert [{:server, server}] = said()

      refute Map.has_key?(server[:mail]["smtp"], "username")
    end

    test "given to the version that runs, is named in the command that installs it",
         %{opts: opts} do
      runs(recorded("0.10.0"))

      {0, stdout, ""} =
        ehosctl(~w(upgrade --smtp-host smtp.example.com --mail-from ehos@example.com), opts)

      assert stdout =~ "so the mail settings were not applied either"

      assert stdout =~
               "--version 0.10.0 --mail-from ehos@example.com --smtp-host smtp.example.com`"

      refute_received {:server, _server}

      runs(recorded("0.10.0"))
      stub_env(Map.put(@env, "SMTP_PASSWORD", "pw"))

      {0, stdout, ""} =
        ehosctl(
          [
            "upgrade",
            "--smtp-host",
            "smtp.example.com",
            "--smtp-username",
            "ehos",
            "--mail-from",
            "o'brien@example.com"
          ],
          opts
        )

      assert stdout =~ "and SMTP_PASSWORD was not written"
      # Quoted as a POSIX shell reads it, so the command can be pasted.
      assert stdout =~ ~S(--mail-from 'o'\''brien@example.com')

      # On the version that runs, the answer is the install command, not a refusal it would make.
      runs(recorded("0.10.0"), %{mail: @mail})
      stub_env(Map.delete(@env, "SMTP_PASSWORD"))
      {0, stdout, ""} = ehosctl(~w(upgrade --smtp-username bob), opts)
      assert stdout =~ "--version 0.10.0 --smtp-username bob`"
    end
  end

  test "changes nothing when the question is not answered yes", %{opts: opts} do
    {0, stdout, ""} = ehosctl(~w(upgrade), opts)
    assert stdout =~ "Nothing was changed."
    assert_received {:asked, _question}
    refute_received {:server, _server}
  end

  test "asks nothing with --yes, nor when no release on the way migrates", %{opts: opts} do
    {0, _stdout, ""} = ehosctl(~w(upgrade --yes), opts)
    refute_received {:asked, _question}
    assert installed_version() == "0.7.0"

    runs(recorded("0.6.0"))
    {0, _stdout, ""} = ehosctl(~w(upgrade), opts)
    refute_received {:asked, _question}
    assert installed_version() == "0.7.0"
  end

  test "asks when a release on the way does not say whether it migrates", %{
    github: github,
    opts: opts
  } do
    FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [
      release("0.7.0", %{}),
      release("0.6.0", %{"migrates" => false})
    ])

    runs(recorded("0.6.0"))
    {0, _stdout, ""} = ehosctl(~w(upgrade), opts)
    assert_received {:asked, question}
    assert question =~ "EHOS 0.7.0 changes the governance database, or does not say"
  end

  test "moves to the release --to names, and refuses one EHOS does not have", %{opts: opts} do
    Process.put(:answer, true)
    {0, _stdout, ""} = ehosctl(~w(upgrade --to 0.6.0), opts)
    assert installed_version() == "0.6.0"
    refute printed() =~ "What 0.7.0 changed."

    {2, "", stderr} = ehosctl(~w(upgrade --to 0.4.0), opts)
    assert stderr =~ "EHOS has no release 0.4.0"
  end

  test "refuses a downgrade without --allow-downgrade, and asks before one with it", %{
    opts: opts
  } do
    runs(recorded("0.7.0"))
    {2, "", stderr} = ehosctl(~w(upgrade --to 0.5.0), opts)
    assert stderr =~ "trial runs EHOS 0.7.0, and 0.5.0 is older"
    assert stderr =~ "Migrations do not run backwards"
    assert stderr =~ "--allow-downgrade"
    refute_received {:server, _server}

    Process.put(:answer, true)
    {0, _stdout, ""} = ehosctl(~w(upgrade --to 0.5.0 --allow-downgrade), opts)
    assert_received {:asked, question}
    assert question =~ "EHOS 0.5.0 will run on the governance database as 0.7.0 left it"
    assert printed() =~ "moving it down to 0.5.0"
    assert installed_version() == "0.5.0"
  end

  test "changes nothing for the version that runs, and refuses it when its release changed", %{
    opts: opts
  } do
    runs(recorded("0.7.0"))
    {0, stdout, ""} = ehosctl(~w(upgrade), opts)
    assert stdout =~ "runs EHOS 0.7.0 already. Nothing was changed"
    assert stdout =~ "`ehosctl install --installation trial --version 0.7.0`"
    refute_received {:server, _server}

    runs(%{recorded("0.7.0") | "image" => image("0.1.0")})
    {1, "", stderr} = ehosctl(~w(upgrade), opts)
    assert stderr =~ "trial runs EHOS 0.7.0 as #{image("0.1.0")}"
    assert stderr =~ "but its release now names #{image("0.7.0")}"
    refute_received {:server, _server}
  end

  test "says why a release's notes could not be read, under its version", %{
    github: github,
    opts: opts
  } do
    {tag, fields} = release("0.7.0", %{"migrates" => false})
    too_long = String.duplicate("x", 2 * 1024 * 1024 + 1)

    FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [
      {tag, put_in(fields, ["assets", "notes.md"], too_long)},
      release("0.6.0", %{"migrates" => false})
    ])

    runs(recorded("0.6.0"))
    {0, _stdout, ""} = ehosctl(~w(upgrade), opts)
    printed = printed()
    assert printed =~ ~r/# ehos 0\.7\.0 .*Its notes could not be read: /s
    refute printed =~ "left out"
  end

  test "says nothing is installed before it asks GitHub", %{github: github, opts: opts} do
    Bypass.down(github)
    runs(:none)
    {2, "", stderr} = ehosctl(~w(upgrade), opts)
    assert stderr =~ "trial runs no EHOS to upgrade"
  end

  test "says a release it could not read, rather than that no release's image matches", %{
    github: github,
    opts: opts
  } do
    FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [
      release("0.7.0", %{}),
      {"v0.6.0", %{"assets" => %{"release.json" => "not json"}}}
    ])

    runs(:unknown, %{digest: digest("0.6.0")})
    {2, "", stderr} = ehosctl(~w(upgrade), opts)
    assert stderr =~ "could not read every release to find the one whose image it runs (v0.6.0: "
    assert stderr =~ "Give --allow-unrecorded"
    refute_received {:server, _server}

    # Which --allow-unrecorded then gets past, after the question.
    Process.put(:answer, true)
    {0, _stdout, ""} = ehosctl(~w(upgrade --allow-unrecorded), opts)
    assert_received {:asked, _question}
    assert installed_version() == "0.7.0"

    runs(:unknown, %{digest: nil})
    {2, "", stderr} = ehosctl(~w(upgrade), opts)
    assert stderr =~ "its image's digest could not be read either"
  end

  test "asks when a release on the way could not be read, and says so", %{
    github: github,
    opts: opts
  } do
    FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [
      release("0.7.0", %{"migrates" => false}),
      {"v0.6.0", %{"assets" => %{"release.json" => "not json"}}},
      release("0.5.0", %{"migrates" => false})
    ])

    {0, _stdout, ""} = ehosctl(~w(upgrade), opts)
    assert_received {:asked, question}

    assert question =~
             "The release.json of EHOS 0.6.0 could not be read to say whether it changes the " <>
               "governance database. EHOS keeps no backup of that database"

    refute question =~ "EHOS 0.7.0"
  end

  test "prints the notes of the newest 50 releases on the way, and weighs the rest as migrating",
       %{github: github, opts: opts} do
    releases = for n <- 52..0//-1, do: release("1.0.#{n}", %{"migrates" => false})
    FakeGitHub.releases(github, "EmpoweredHouse/eh-os", releases)
    runs(recorded("1.0.0"))

    {0, _stdout, ""} = ehosctl(~w(upgrade), opts)
    printed = printed()
    assert printed =~ "What 1.0.52 changed." and printed =~ "What 1.0.3 changed."
    refute printed =~ "What 1.0.2 changed."
    assert printed =~ "2 older releases are left out: their notes are at"
    assert_received {:asked, question}
    assert question =~ "2 older releases on the way were not read, and may change the governance"
  end

  test "takes over an EHOS that recorded nothing by its image's digest", %{opts: opts} do
    Process.put(:answer, true)
    runs(:unknown, %{digest: digest("0.6.0")})
    {0, _stdout, ""} = ehosctl(~w(upgrade), opts)
    assert printed() =~ "trial runs EHOS 0.6.0, by its image's digest; moving it to 0.7.0."
    refute_received {:asked, _question}
    assert installed_version() == "0.7.0"

    # Matched to the target itself, it is installed again from its release, which records it.
    runs(:unknown, %{digest: digest("0.7.0")})
    {0, _stdout, ""} = ehosctl(~w(upgrade), opts)
    # Nothing on the way, so no notes: the heading alone.
    assert_received {:printed, heading}
    assert heading =~ "by its image's digest, but recorded nothing; installing it again"
    refute_received {:printed, _notes}
    assert installed_version() == "0.7.0"
  end

  test "moves an EHOS no release's image matches only with --allow-unrecorded, after asking", %{
    opts: opts
  } do
    for {digest, why} <- [
          {digest("0.1.0"), "its image is no release's"},
          {nil, "its image's digest could not be read either"}
        ] do
      runs(:unknown, %{digest: digest})
      {2, "", stderr} = ehosctl(~w(upgrade), opts)
      assert stderr =~ "whose version nothing recorded, and #{why}"
      assert stderr =~ "--allow-unrecorded"
      refute_received {:server, _server}
    end

    Process.put(:answer, true)
    {0, _stdout, ""} = ehosctl(~w(upgrade --allow-unrecorded), opts)
    assert_received {:asked, question}
    assert question =~ "Moving to 0.7.0 may change the governance database"
    printed = printed()
    assert printed =~ "What 0.7.0 changed."
    refute printed =~ "What 0.6.0 changed."
    assert installed_version() == "0.7.0"
  end

  test "refuses where nothing is installed, or under a revision still pending", %{opts: opts} do
    runs(:none)
    {2, "", stderr} = ehosctl(~w(upgrade), opts)
    assert stderr =~ "trial runs no EHOS to upgrade: `ehosctl install --installation trial`"

    runs(recorded("0.5.0"), %{
      last: %{revision: 7, status: "pending-upgrade", description: "Preparing upgrade"}
    })

    {1, "", stderr} = ehosctl(~w(upgrade), opts)
    assert stderr =~ "Helm's revision 7, is pending-upgrade"
    refute_received {:server, _server}
  end

  test "moves on from what deployed after an attempt that failed, and says so", %{opts: opts} do
    runs(recorded("0.6.0"), %{
      last: %{revision: 3, status: "failed", description: "timed out waiting"}
    })

    {0, stdout, ""} = ehosctl(~w(upgrade), opts)
    assert stdout =~ "The last attempt, Helm's revision 3, had failed (timed out waiting)."
    assert printed() =~ "trial runs EHOS 0.6.0; moving it to 0.7.0."
    assert installed_version() == "0.7.0"
  end

  test "says what stops it before it asks GitHub, as an unopened tunnel", %{
    github: github,
    opts: opts
  } do
    Bypass.down(github)

    Process.put(
      {Platform, :installed},
      {:error, "Open the tunnel first: `ehosctl server tunnel`"}
    )

    {1, "", stderr} = ehosctl(~w(upgrade), opts)
    assert stderr =~ "Open the tunnel first"
  end

  test "says in its help that it is on the platform plane", %{opts: opts} do
    {0, help, ""} = ehosctl(~w(upgrade --help), opts)
    assert help =~ "Plane: platform."
    assert help =~ "--allow-downgrade"
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

    {2, "", stderr} = ehosctl(~w(upgrade --yes), opts)

    assert stderr =~
             "No server is known under ehos-92-5-148-138 (the current installation); servers " <>
               "on this machine: acme, trial. Run the command again with --installation and " <>
               "one of them."

    refute_received {:installed, _opts}
    refute_received {:server, _opts}
  end
end
