defmodule Ehosctl.UpgradeTest do
  # Not async: capture_io(:stderr) captures stderr for every process.
  use Ehosctl.Case, async: false

  alias Ehosctl.FakeGitHub
  alias Ehosctl.FakeHTTP

  @moduletag :tmp_dir

  @env %{"GHCR_TOKEN" => "ghp_token", "EHOS_STATE_PASSPHRASE" => "a passphrase of 16+"}

  @host "ehos.acme.example.org"

  @mail %{
    "from" => "ehos@example.com",
    "smtp" => %{"host" => "smtp.example.com", "port" => 587, "username" => "ehos"}
  }

  @no_user %{
    "from" => "ehos@example.com",
    "smtp" => %{"host" => "smtp.example.com", "port" => 587}
  }

  # eh-os D-141: a relay that admits the server by its address admits every application on it.
  @no_user_warning "==> Warning: EHOS sends mail through smtp.example.com:587 with no SMTP " <>
                     "user. A relay that admits the server by its address admits every " <>
                     "application on it, so one that names smtp.example.com under needs.egress " <>
                     "can send as anyone in the company's domain, around its mail agreement. " <>
                     "Where applications other than the company's own run, give EHOS a relay " <>
                     "user (--smtp-username, with SMTP_PASSWORD) and have the relay require it " <>
                     "rather than admit the server by its address (eh-os D-141).\n"

  # What a move says it keeps, as the setup's EHOS runs: its console, and no mail; and with four
  # eyes off.
  @console_alone "Its console stays at https://ehos.acme.example.org. It sends no mail."
  @self_approval "Its console stays at https://ehos.acme.example.org. Whoever deployed or asked " <>
                   "for a promotion may approve it, without a second person. It sends no mail."

  @installed_trial """
  EHOS is running at https://ehos.acme.example.org.
  Sign in with `ehosctl login --installation trial`: it trusts the installation's CA.
  """

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
      # Said on stderr too where a test asks, so it sees what came before the install.
      if Process.get({__MODULE__, :on_stderr}), do: IO.write(:stderr, "[installed]\n")
      dir = opts[:home] |> Path.expand() |> Path.join(opts[:name])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "install.json"), ~s({"host":"ehos.acme.example.org"}))
      File.write!(Path.join(dir, "ca.crt"), Process.get({__MODULE__, :ca}))
      {:ok, "EHOS is running at https://ehos.acme.example.org."}
    end
  end

  setup %{tmp_dir: dir} do
    github = FakeGitHub.start()
    %{cert: der} = :public_key.pkix_test_root_cert(~c"EHOS CA", [])
    Process.put({Platform, :ca}, :public_key.pem_encode([{:Certificate, der, :not_encrypted}]))
    test_pid = self()
    stub_env(@env)

    opts =
      [
        install: Platform,
        home: Path.join(dir, "ehos"),
        config_dir: Path.join(dir, "config")
      ]

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

  describe "upgrade" do
    test "moves to the newest release after the notes on the way, asking first since one migrates",
         %{opts: opts} do
      Process.put(:answer, true)

      # Newest first, the releases after 0.5.0 up to 0.7.0, and not 0.5.0 itself.
      assert ehosctl(~w(upgrade --installation acme), opts) ==
               {0,
                """
                acme runs EHOS 0.5.0; moving it to 0.7.0.
                Its console stays at https://ehos.acme.example.org. It sends no mail.

                #{note("0.7.0")}

                #{note("0.6.0")}
                EHOS is running at https://ehos.acme.example.org.
                Sign in with `ehosctl login --installation acme`: it trusts the installation's CA.
                """, ""}

      assert_received {:installed, installed}

      assert installed == [
               name: "acme",
               home: opts[:home],
               runner: Ehosctl.PlatformRunner,
               server_command: "ehosctl server",
               name_option: "--installation",
               name_in_commands: true
             ]

      # The console stays where it is; eh-os#823: the switch, for a server running k3s's Traefik,
      # only when asked.
      assert said() == [
               {:asked, migrates("0.6.0", "0.7.0")},
               {:server, install(opts, "acme", "0.7.0")}
             ]
    end

    # eh-os#823: a server running k3s's Traefik is switched only when asked, with the key given.
    test "passes --switch-traefik and --ssh-key to the install", %{opts: opts} do
      Process.put(:answer, true)

      {0, _stdout, ""} =
        ehosctl(~w(upgrade --installation acme --switch-traefik --ssh-key /keys/acme), opts)

      assert said() == [
               {:asked, migrates("0.6.0", "0.7.0")},
               {:server,
                install(opts, "acme", "0.7.0", switch_traefik: true, ssh_key: "/keys/acme")}
             ]
    end

    # eh-os D-141: the person answers knowing that a relay without a user admits every application.
    test "warns of an SMTP server with no user before it asks", %{opts: opts} do
      runs(recorded("0.5.0"), %{mail: @no_user})
      mock_asked_on_stderr()

      assert ehosctl(~w(upgrade), opts) ==
               {0,
                """
                trial runs EHOS 0.5.0; moving it to 0.7.0.
                Its console stays at https://ehos.acme.example.org. It sends mail from ehos@example.com through smtp.example.com:587.

                #{note("0.7.0")}

                #{note("0.6.0")}
                """ <> @installed_trial, @no_user_warning <> "[asked]\n"}

      assert said() == [
               {:asked, migrates("0.6.0", "0.7.0")},
               {:server, install(opts, "trial", "0.7.0", mail: @no_user)}
             ]
    end

    # eh-os D-124: the console's host of sslip.io would name the server's old address.
    test "is refused while the console's host names the server's old address, and --host moves it",
         %{opts: opts, github: github} do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [
        release("0.10.0", %{"migrates" => false}),
        release("0.9.0", %{"migrates" => false})
      ])

      runs(recorded("0.9.0"), %{host: "ehos.192-0-2-1.sslip.io"})

      File.write!(
        Path.join([opts[:home], "trial", "tunnel.json"]),
        ~s({"address": "198.51.100.9"})
      )

      assert ehosctl(~w(upgrade --yes), opts) ==
               {2, "",
                "ehosctl: EHOS on trial serves its console at ehos.192-0-2-1.sslip.io, which " <>
                  "names 192.0.2.1, but the server is at 198.51.100.9 now (eh-os D-124). To move " <>
                  "the console, and every application's address with it, give --host " <>
                  "ehos.198-51-100-9.sslip.io. Nothing was changed.\n"}

      assert said() == []

      # `upgrade` moves the host itself, which an EHOS whose version nothing recorded needs:
      # `install` refuses it.
      assert ehosctl(~w(upgrade --yes --host ehos.198-51-100-9.sslip.io), opts) ==
               {0,
                """
                trial runs EHOS 0.9.0; moving it to 0.10.0.
                Its console stays at https://ehos.198-51-100-9.sslip.io. It sends no mail.

                #{note("0.10.0")}
                """ <> @installed_trial, ""}

      assert said() == [
               {:server, install(opts, "trial", "0.10.0", host: "ehos.198-51-100-9.sslip.io")}
             ]
    end

    test "asks nothing with --yes, nor when no release on the way migrates", %{opts: opts} do
      assert ehosctl(~w(upgrade --yes), opts) ==
               {0,
                """
                trial runs EHOS 0.5.0; moving it to 0.7.0.
                Its console stays at https://ehos.acme.example.org. It sends no mail.

                #{note("0.7.0")}

                #{note("0.6.0")}
                """ <> @installed_trial, ""}

      assert said() == [{:server, install(opts, "trial", "0.7.0")}]

      runs(recorded("0.6.0"))

      assert ehosctl(~w(upgrade), opts) ==
               {0,
                """
                trial runs EHOS 0.6.0; moving it to 0.7.0.
                Its console stays at https://ehos.acme.example.org. It sends no mail.

                #{note("0.7.0")}
                """ <> @installed_trial, ""}

      assert said() == [{:server, install(opts, "trial", "0.7.0")}]
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

      assert ehosctl(~w(upgrade), opts) ==
               {0,
                """
                trial runs EHOS 0.6.0; moving it to 0.7.0.
                Its console stays at https://ehos.acme.example.org. It sends no mail.

                #{note("0.7.0")}
                Nothing was changed.
                """, ""}

      assert said() == [{:asked, migrates("0.7.0", "0.7.0")}]
    end

    test "moves to the release --to names, and refuses one EHOS does not have", %{opts: opts} do
      Process.put(:answer, true)

      assert ehosctl(~w(upgrade --to 0.6.0), opts) ==
               {0,
                """
                trial runs EHOS 0.5.0; moving it to 0.6.0.
                Its console stays at https://ehos.acme.example.org. It sends no mail.

                #{note("0.6.0")}
                """ <> @installed_trial, ""}

      assert said() == [
               {:asked, migrates("0.6.0", "0.6.0")},
               {:server, install(opts, "trial", "0.6.0")}
             ]

      assert ehosctl(~w(upgrade --to 0.4.0), opts) ==
               {2, "", "ehosctl: EHOS has no release 0.4.0.\n"}
    end

    test "refuses a downgrade without --allow-downgrade, and asks before one with it", %{
      opts: opts
    } do
      runs(recorded("0.7.0"))

      assert ehosctl(~w(upgrade --to 0.5.0), opts) ==
               {2, "",
                "ehosctl: trial runs EHOS 0.7.0, and 0.5.0 is older. Migrations do not run " <>
                  "backwards, so its code would meet the database 0.7.0 left. Give " <>
                  "--allow-downgrade to go down anyway. Nothing was changed.\n"}

      assert said() == []

      Process.put(:answer, true)

      assert ehosctl(~w(upgrade --to 0.5.0 --allow-downgrade), opts) ==
               {0,
                """
                trial runs EHOS 0.7.0; moving it down to 0.5.0.
                Its console stays at https://ehos.acme.example.org. It sends no mail.

                #{note("0.7.0")}

                #{note("0.6.0")}
                """ <> @installed_trial, ""}

      assert said() == [
               {:asked,
                "EHOS 0.5.0 will run on the governance database as 0.7.0 left it, which it may " <>
                  "not read, and EHOS keeps no backup of it to go back to. Move down to 0.5.0? " <>
                  "[y/N] "},
               {:server, install(opts, "trial", "0.5.0")}
             ]
    end

    test "changes nothing for the version that runs, and refuses it when its release changed", %{
      opts: opts
    } do
      runs(recorded("0.7.0"))

      assert ehosctl(~w(upgrade), opts) ==
               {0,
                "trial runs EHOS 0.7.0 already. Nothing was changed; `ehosctl install " <>
                  "--installation trial --version 0.7.0` installs it again.\n", ""}

      assert said() == []

      runs(%{recorded("0.7.0") | "image" => image("0.1.0")})

      assert ehosctl(~w(upgrade), opts) ==
               {1, "",
                "ehosctl: trial runs EHOS 0.7.0 as #{image("0.1.0")}, from #{chart("0.7.0")}, " <>
                  "but its release now names #{image("0.7.0")}, from #{chart("0.7.0")}. A " <>
                  "release is not changed once published: find out who changed it before " <>
                  "installing anything from it. Nothing was changed.\n"}

      assert said() == []
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

      assert ehosctl(~w(upgrade), opts) ==
               {0,
                """
                trial runs EHOS 0.6.0; moving it to 0.7.0.
                Its console stays at https://ehos.acme.example.org. It sends no mail.

                #{note("0.7.0", "Its notes could not be read: https://api.github.com answered with more than 2097152 bytes, more than ehosctl reads from it.")}
                """ <> @installed_trial, ""}
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

      assert ehosctl(~w(upgrade), opts) ==
               {2, "",
                "ehosctl: trial runs an EHOS whose version nothing recorded, and ehosctl could " <>
                  "not read every release to find the one whose image it runs (v0.6.0: The " <>
                  "release.json of v0.6.0 is not a JSON object.), so ehosctl cannot tell " <>
                  "whether 0.7.0 is newer: it may be a build of a later commit. Give " <>
                  "--allow-unrecorded to move it to 0.7.0 anyway. Nothing was changed.\n"}

      assert said() == []

      # Which --allow-unrecorded then gets past, after the question.
      Process.put(:answer, true)

      assert ehosctl(~w(upgrade --allow-unrecorded), opts) ==
               {0,
                """
                trial runs an EHOS whose version nothing recorded; moving it to 0.7.0.
                Its console stays at https://ehos.acme.example.org. It sends no mail.

                #{note("0.7.0")}
                """ <> @installed_trial, ""}

      assert said() == [
               {:asked, unrecorded("0.7.0")},
               {:server, install(opts, "trial", "0.7.0")}
             ]

      runs(:unknown, %{digest: nil})

      assert ehosctl(~w(upgrade), opts) ==
               {2, "", not_recorded("its image's digest could not be read either")}
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

      assert ehosctl(~w(upgrade), opts) ==
               {0,
                """
                trial runs EHOS 0.5.0; moving it to 0.7.0.
                Its console stays at https://ehos.acme.example.org. It sends no mail.

                #{note("0.7.0")}

                #{note("0.6.0", "Notes of v0.6.0.")}
                Nothing was changed.
                """, ""}

      assert said() == [
               {:asked,
                "The release.json of EHOS 0.6.0 could not be read to say whether it changes the " <>
                  "governance database. EHOS keeps no backup of that database: once changed, it " <>
                  "cannot go back. Move to 0.7.0? [y/N] "}
             ]
    end

    test "prints the notes of the newest 50 releases on the way, and weighs the rest as migrating",
         %{github: github, opts: opts} do
      releases = for n <- 52..0//-1, do: release("1.0.#{n}", %{"migrates" => false})
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", releases)
      runs(recorded("1.0.0"))

      assert ehosctl(~w(upgrade), opts) ==
               {0,
                """
                trial runs EHOS 1.0.0; moving it to 1.0.52.
                Its console stays at https://ehos.acme.example.org. It sends no mail.

                #{Enum.map_join(52..3//-1, "\n\n", &note("1.0.#{&1}"))}

                2 older releases are left out: their notes are at https://github.com/EmpoweredHouse/eh-os/releases.
                Nothing was changed.
                """, ""}

      assert said() == [
               {:asked,
                "2 older releases on the way were not read, and may change the governance " <>
                  "database. EHOS keeps no backup of that database: once changed, it cannot go " <>
                  "back. Move to 1.0.52? [y/N] "}
             ]
    end

    test "takes over an EHOS that recorded nothing by its image's digest", %{opts: opts} do
      Process.put(:answer, true)
      runs(:unknown, %{digest: digest("0.6.0")})

      assert ehosctl(~w(upgrade), opts) ==
               {0,
                """
                trial runs EHOS 0.6.0, by its image's digest; moving it to 0.7.0.
                Its console stays at https://ehos.acme.example.org. It sends no mail.

                #{note("0.7.0")}
                """ <> @installed_trial, ""}

      assert said() == [{:server, install(opts, "trial", "0.7.0")}]

      # Matched to the target itself, it is installed again from its release, which records it.
      # Nothing on the way, so no notes: the heading alone.
      runs(:unknown, %{digest: digest("0.7.0")})

      assert ehosctl(~w(upgrade), opts) ==
               {0,
                """
                trial runs EHOS 0.7.0, by its image's digest, but recorded nothing; installing it again from its release records it.
                Its console stays at https://ehos.acme.example.org. It sends no mail.
                """ <> @installed_trial, ""}

      assert said() == [{:server, install(opts, "trial", "0.7.0")}]
    end

    test "moves an EHOS no release's image matches only with --allow-unrecorded, after asking", %{
      opts: opts
    } do
      for {digest, why} <- [
            {digest("0.1.0"), "its image is no release's"},
            {nil, "its image's digest could not be read either"}
          ] do
        runs(:unknown, %{digest: digest})
        assert ehosctl(~w(upgrade), opts) == {2, "", not_recorded(why)}
        assert said() == []
      end

      Process.put(:answer, true)

      assert ehosctl(~w(upgrade --allow-unrecorded), opts) ==
               {0,
                """
                trial runs an EHOS whose version nothing recorded; moving it to 0.7.0.
                Its console stays at https://ehos.acme.example.org. It sends no mail.

                #{note("0.7.0")}
                """ <> @installed_trial, ""}

      assert said() == [
               {:asked, unrecorded("0.7.0")},
               {:server, install(opts, "trial", "0.7.0")}
             ]
    end

    test "moves on from what deployed after an attempt that failed, and says so", %{opts: opts} do
      runs(recorded("0.6.0"), %{
        last: %{revision: 3, status: "failed", description: "timed out waiting"}
      })

      assert ehosctl(~w(upgrade), opts) ==
               {0,
                """
                trial runs EHOS 0.6.0; moving it to 0.7.0.
                Its console stays at https://ehos.acme.example.org. It sends no mail.

                #{note("0.7.0")}
                The last attempt, Helm's revision 3, had failed (timed out waiting).
                """ <> @installed_trial, ""}

      assert said() == [{:server, install(opts, "trial", "0.7.0")}]
    end

    test "says in its help that it is on the platform plane", %{opts: opts} do
      assert ehosctl(~w(upgrade --help), opts) ==
               {0,
                """
                ehosctl #{Ehosctl.version()}
                Move EHOS on the server under an installation to another release, after its notes, through its tunnel, with your kubeconfig and GHCR_TOKEN, and SMTP_PASSWORD for an SMTP server's user.

                USAGE:
                    ehosctl upgrade [--allow-downgrade] [--allow-unrecorded] [--yes] [--four-eyes] [--no-four-eyes] [--no-mail] [--switch-traefik] [--installation NAME] [--to V] [--host HOST] [--sign-in-absolute DURATION] [--sign-in-idle DURATION] [--smtp-host HOST] [--smtp-port PORT] [--smtp-username USER] [--mail-from ADDRESS] [--ssh-key PATH]

                FLAGS:

                    --allow-downgrade         Move to a lower version too. Migrations do not run
                                              backwards: the older code meets the database the
                                              newer one left.
                    --allow-unrecorded        Move an EHOS whose version nothing recorded and no
                                              release's image matches, as `mix ehos.install`
                                              may leave it.
                    --yes                     Do not ask.
                    --four-eyes               Turn four eyes on: a promotion to production needs
                                              a second person, neither who deployed the
                                              candidate nor who asked. A new EHOS 0.14.0 or
                                              later runs without them.
                    --no-four-eyes            Let who deployed or asked approve their own
                                              promotion, each recorded as a self-approval: for
                                              an installation of one person. Kept by later
                                              upgrades.
                    --no-mail                 Send no mail: forget the SMTP server EHOS runs
                                              with. Its password stays in the cluster.
                    --switch-traefik          Switch a server that runs k3s's Traefik, as one
                                              made before EHOS 0.15.0's modules does, to EHOS's
                                              own: k3s restarts without it, and the console and
                                              its applications are down for a few minutes.
                                              Refused without it. Needs EHOS_STATE_PASSPHRASE.

                OPTIONS:

                    --installation            The installation whose server this is, instead of
                                              EHOSCTL_INSTALLATION, the current one, or trial.
                    --to                      The EHOS release to move to; the newest by
                                              default.
                    --host                    The console's host, instead of the one EHOS serves
                                              there; every application's address follows it.
                    --sign-in-absolute        How long a person's sign-in to an application
                                              lasts from signing in at EHOS, in hours or days
                                              (12h, 30d), at most 366d; the one EHOS runs with,
                                              else 12h.
                    --sign-in-idle            How long such a sign-in lasts unused, in hours or
                                              days, at most the absolute one; the one EHOS runs
                                              with, else 1h.
                    --smtp-host               The SMTP server EHOS sends mail through, so
                                              invitations arrive by email; the one EHOS runs
                                              with, else none. TLS is always on and verified.
                    --smtp-port               Its port: 587 for STARTTLS (the default), 465 for
                                              TLS from the first byte.
                    --smtp-username           The user to authenticate as, whose password is
                                              SMTP_PASSWORD, or the one the cluster holds; ""
                                              for none.
                    --mail-from               The address EHOS sends mail from; needed with an
                                              SMTP server.
                    --ssh-key                 The private key the server was made with, for
                                              --switch-traefik. The key `ehosctl server up`
                                              recorded by default, else ~/.ssh/ehos_oci.

                Plane: platform. Acts with an account EHOS does not issue: a cloud provider's, an SSH key, or a kubeconfig.

                """, ""}
    end

    test "changes nothing when the question is not answered yes", %{opts: opts} do
      assert ehosctl(~w(upgrade), opts) ==
               {0,
                """
                trial runs EHOS 0.5.0; moving it to 0.7.0.
                Its console stays at https://ehos.acme.example.org. It sends no mail.

                #{note("0.7.0")}

                #{note("0.6.0")}
                Nothing was changed.
                """, ""}

      assert said() == [{:asked, migrates("0.6.0", "0.7.0")}]
    end

    test "says nothing is installed before it asks GitHub", %{github: github, opts: opts} do
      FakeHTTP.down(github)
      runs(:none)

      assert ehosctl(~w(upgrade), opts) ==
               {2, "",
                "ehosctl: trial runs no EHOS to upgrade: `ehosctl install --installation trial` " <>
                  "installs it.\n"}
    end

    test "refuses where nothing is installed, or under a revision still pending", %{opts: opts} do
      runs(:none)

      assert ehosctl(~w(upgrade), opts) ==
               {2, "",
                "ehosctl: trial runs no EHOS to upgrade: `ehosctl install --installation trial` " <>
                  "installs it.\n"}

      runs(recorded("0.5.0"), %{
        last: %{revision: 7, status: "pending-upgrade", description: "Preparing upgrade"}
      })

      helm = "helm --kubeconfig #{opts[:home]}/trial/kubeconfig --kube-context ehos-trial"

      assert ehosctl(~w(upgrade), opts) ==
               {1, "",
                "ehosctl: The last change to EHOS on trial, Helm's revision 7, is " <>
                  "pending-upgrade (Preparing upgrade): an install or upgrade is running, or one " <>
                  "was interrupted. Wait for it to end; if it was interrupted, `#{helm} -n " <>
                  "ehos-system history ehos` shows the revisions, and `#{helm} -n ehos-system " <>
                  "rollback ehos <the last deployed revision>` ends it, before running this " <>
                  "again. Nothing was changed.\n"}

      assert said() == []
    end

    test "says what stops it before it asks GitHub, as an unopened tunnel", %{
      github: github,
      opts: opts
    } do
      FakeHTTP.down(github)

      Process.put(
        {Platform, :installed},
        {:error, "Open the tunnel first: `ehosctl server tunnel`"}
      )

      assert ehosctl(~w(upgrade), opts) ==
               {1, "", "ehosctl: Open the tunnel first: `ehosctl server tunnel`\n"}
    end

    # A server made before Stage 13 is under `trial`, while the current installation is named after
    # its host (ehos-tools#194).
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

      assert ehosctl(~w(upgrade --yes), opts) ==
               {2, "",
                "ehosctl: No server is known under ehos-92-5-148-138 (the current installation); " <>
                  "servers on this machine: acme, trial. Run the command again with " <>
                  "--installation and one of them.\n"}

      refute_received {:installed, _opts}
      assert said() == []
    end
  end

  # eh-os D-113: the limits it was installed with stay, unless the options give others.
  describe "upgrade with sign-in limits" do
    setup %{github: github} do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [
        release("0.10.0", %{"migrates" => false}),
        release("0.7.0", %{"migrates" => false})
      ])

      :ok
    end

    test "keeps them, and takes others the options give", %{opts: opts} do
      runs(recorded("0.7.0"), %{sign_in: %{"absolute" => "30d", "idle" => "14d"}})

      assert ehosctl(~w(upgrade), opts) ==
               {0,
                moved(
                  "0.7.0",
                  "0.10.0",
                  "Its console stays at https://ehos.acme.example.org. A sign-in to an " <>
                    "application lasts 30d, 14d unused. It sends no mail."
                ), ""}

      assert said() == [
               {:server,
                install(opts, "trial", "0.10.0", sign_in: %{"absolute" => "30d", "idle" => "14d"})}
             ]

      runs(recorded("0.7.0"), %{sign_in: %{"absolute" => "30d", "idle" => "14d"}})

      assert ehosctl(~w(upgrade --sign-in-idle 2d), opts) ==
               {0,
                moved(
                  "0.7.0",
                  "0.10.0",
                  "Its console stays at https://ehos.acme.example.org. A sign-in to an " <>
                    "application lasts 30d, 2d unused. It sends no mail."
                ), ""}

      assert said() == [
               {:server,
                install(opts, "trial", "0.10.0", sign_in: %{"absolute" => "30d", "idle" => "2d"})}
             ]

      runs(recorded("0.7.0"))

      assert ehosctl(~w(upgrade), opts) ==
               {0, moved("0.7.0", "0.10.0", @console_alone), ""}

      assert said() == [{:server, install(opts, "trial", "0.10.0")}]
    end

    test "given to the version that runs, names them in the command that installs them",
         %{opts: opts} do
      runs(recorded("0.10.0"))

      assert ehosctl(~w(upgrade --sign-in-absolute 30d --sign-in-idle 14d), opts) ==
               {0,
                "trial runs EHOS 0.10.0 already. Nothing was changed, so the sign-in limits were " <>
                  "not applied either; `ehosctl install --installation trial --version 0.10.0 " <>
                  "--sign-in-absolute 30d --sign-in-idle 14d` installs it again.\n", ""}

      assert said() == []
    end

    test "sends them to no EHOS before 0.10.0, and does not say them", %{opts: opts} do
      runs(recorded("0.10.0"), %{sign_in: %{"absolute" => "30d"}})

      assert ehosctl(~w(upgrade --to 0.7.0 --allow-downgrade --yes), opts) ==
               {0,
                """
                trial runs EHOS 0.10.0; moving it down to 0.7.0.
                Its console stays at https://ehos.acme.example.org. It sends no mail.

                #{note("0.10.0")}
                """ <> @installed_trial, ""}

      assert said() == [{:server, install(opts, "trial", "0.7.0")}]
    end

    test "refuses them as the chart would refuse them, before anything changes", %{opts: opts} do
      runs(recorded("0.7.0"), %{sign_in: %{"absolute" => "30d"}})

      assert ehosctl(~w(upgrade --sign-in-idle 31d), opts) ==
               {2, "",
                "ehosctl: --sign-in-idle (31d) must be at most the absolute limit EHOS runs with " <>
                  "(30d)\n"}

      assert said() == []
    end
  end

  # eh-os D-105, ehos-tools#296: four eyes turned off stay off, unless --four-eyes says otherwise.
  describe "upgrade with four eyes" do
    setup %{github: github} do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [
        release("0.10.0", %{"migrates" => false}),
        release("0.9.0", %{"migrates" => false}),
        release("0.8.0", %{"migrates" => false})
      ])

      :ok
    end

    test "keeps them and says so when off, and the flags change them", %{opts: opts} do
      runs(recorded("0.9.0"), %{four_eyes: false})

      assert ehosctl(~w(upgrade --yes), opts) ==
               {0, moved("0.9.0", "0.10.0", @self_approval), ""}

      assert said() == [{:server, install(opts, "trial", "0.10.0", four_eyes: false)}]

      runs(recorded("0.9.0"), %{four_eyes: false})

      assert ehosctl(~w(upgrade --four-eyes --yes), opts) ==
               {0, moved("0.9.0", "0.10.0", @console_alone), ""}

      assert said() == [{:server, install(opts, "trial", "0.10.0", four_eyes: true)}]

      runs(recorded("0.9.0"))

      assert ehosctl(~w(upgrade --no-four-eyes --yes), opts) ==
               {0, moved("0.9.0", "0.10.0", @self_approval), ""}

      assert said() == [{:server, install(opts, "trial", "0.10.0", four_eyes: false)}]
    end

    test "given to the version that runs, names them in the command that installs them",
         %{opts: opts} do
      runs(recorded("0.10.0"))

      assert ehosctl(~w(upgrade --no-four-eyes --sign-in-absolute 30d), opts) ==
               {0,
                "trial runs EHOS 0.10.0 already. Nothing was changed, so the sign-in limits and " <>
                  "the four-eyes setting were not applied either; `ehosctl install " <>
                  "--installation trial --version 0.10.0 --sign-in-absolute 30d --no-four-eyes` " <>
                  "installs it again.\n", ""}

      assert said() == []

      assert ehosctl(~w(upgrade --no-four-eyes), opts) ==
               {0,
                "trial runs EHOS 0.10.0 already. Nothing was changed, so the four-eyes setting " <>
                  "was not applied either; `ehosctl install --installation trial --version " <>
                  "0.10.0 --no-four-eyes` installs it again.\n", ""}

      argv = ~w(upgrade --sign-in-idle 1h --four-eyes --smtp-host h.example.com --mail-from a@b.c)

      assert ehosctl(argv, opts) ==
               {0,
                "trial runs EHOS 0.10.0 already. Nothing was changed, so the sign-in limits, the " <>
                  "four-eyes setting and the mail settings were not applied either; `ehosctl " <>
                  "install --installation trial --version 0.10.0 --sign-in-idle 1h --four-eyes " <>
                  "--mail-from a@b.c --smtp-host h.example.com` installs it again.\n", ""}
    end

    # eh-os D-128, ehos-tools#350: left to a chart that keeps what runs, they are as the server runs
    # them.
    test "left to the chart, says them when off as the server runs them, where the chart keeps that",
         %{github: github, opts: opts} do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [
        release("0.14.0", %{"migrates" => false}),
        release("0.13.0", %{"migrates" => false}),
        release("0.12.0", %{"migrates" => false})
      ])

      runs(recorded("0.13.0"), %{four_eyes_runs: false})

      assert ehosctl(~w(upgrade --yes), opts) ==
               {0, moved("0.13.0", "0.14.0", @self_approval), ""}

      assert said() == [{:server, install(opts, "trial", "0.14.0")}]

      runs(recorded("0.13.0"), %{four_eyes_runs: true})

      assert ehosctl(~w(upgrade --yes), opts) ==
               {0, moved("0.13.0", "0.14.0", @console_alone), ""}

      assert said() == [{:server, install(opts, "trial", "0.14.0")}]

      # Not read, as on a server before 0.9.0 or a call that failed, it is not said.
      runs(recorded("0.13.0"))

      assert ehosctl(~w(upgrade --yes), opts) ==
               {0, moved("0.13.0", "0.14.0", @console_alone), ""}

      assert said() == [{:server, install(opts, "trial", "0.14.0")}]

      # Turned on by the flag, whatever runs.
      runs(recorded("0.13.0"), %{four_eyes_runs: false})

      assert ehosctl(~w(upgrade --four-eyes --yes), opts) ==
               {0, moved("0.13.0", "0.14.0", @console_alone), ""}

      assert said() == [{:server, install(opts, "trial", "0.14.0", four_eyes: true)}]

      # A chart before 0.14.0 turns them on when given nothing, whatever runs.
      runs(recorded("0.12.0"), %{four_eyes_runs: false})

      assert ehosctl(~w(upgrade --to 0.13.0 --yes), opts) ==
               {0,
                """
                trial runs EHOS 0.12.0; moving it to 0.13.0.
                #{@console_alone}

                #{note("0.13.0")}
                """ <> @installed_trial, ""}

      assert said() == [{:server, install(opts, "trial", "0.13.0")}]
    end

    test "sends them to no EHOS before 0.9.0, and does not say them", %{opts: opts} do
      runs(recorded("0.9.0"), %{four_eyes: false})

      assert ehosctl(~w(upgrade --to 0.8.0 --allow-downgrade --yes), opts) ==
               {0,
                """
                trial runs EHOS 0.9.0; moving it down to 0.8.0.
                #{@console_alone}

                #{note("0.9.0")}
                """ <> @installed_trial, ""}

      assert said() == [{:server, install(opts, "trial", "0.8.0")}]
    end
  end

  # eh-os D-36, ehos-tools#298: kept as the sign-in limits are.
  describe "upgrade with an SMTP server" do
    setup %{github: github} do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [
        release("0.10.0", %{"migrates" => false}),
        release("0.7.0", %{"migrates" => false})
      ])

      :ok
    end

    test "keeps it and says it, and the options change it", %{opts: opts} do
      runs(recorded("0.7.0"), %{mail: @mail})

      assert ehosctl(~w(upgrade), opts) ==
               {0,
                moved(
                  "0.7.0",
                  "0.10.0",
                  "Its console stays at https://ehos.acme.example.org. It sends mail from " <>
                    "ehos@example.com through smtp.example.com:587 as ehos."
                ), ""}

      assert said() == [{:server, install(opts, "trial", "0.10.0", mail: @mail)}]

      runs(recorded("0.7.0"), %{mail: @mail})

      assert ehosctl(~w(upgrade --mail-from team@example.com), opts) ==
               {0,
                moved(
                  "0.7.0",
                  "0.10.0",
                  "Its console stays at https://ehos.acme.example.org. It sends mail from " <>
                    "team@example.com through smtp.example.com:587 as ehos."
                ), ""}

      assert said() == [
               {:server,
                install(opts, "trial", "0.10.0", mail: %{@mail | "from" => "team@example.com"})}
             ]

      runs(recorded("0.7.0"), %{mail: @mail})

      assert ehosctl(~w(upgrade --no-mail), opts) ==
               {0, moved("0.7.0", "0.10.0", @console_alone), ""}

      assert said() == [{:server, install(opts, "trial", "0.10.0")}]
    end

    test "without a user, warns of it, and the upgrade goes on", %{opts: opts} do
      runs(recorded("0.7.0"), %{mail: @no_user})

      assert ehosctl(~w(upgrade), opts) ==
               {0,
                moved(
                  "0.7.0",
                  "0.10.0",
                  "Its console stays at https://ehos.acme.example.org. It sends mail from " <>
                    "ehos@example.com through smtp.example.com:587."
                ), @no_user_warning}

      assert said() == [{:server, install(opts, "trial", "0.10.0", mail: @no_user)}]

      # With a user, nothing is said.
      runs(recorded("0.7.0"), %{mail: @mail})

      assert ehosctl(~w(upgrade), opts) ==
               {0,
                moved(
                  "0.7.0",
                  "0.10.0",
                  "Its console stays at https://ehos.acme.example.org. It sends mail from " <>
                    "ehos@example.com through smtp.example.com:587 as ehos."
                ), ""}

      assert said() == [{:server, install(opts, "trial", "0.10.0", mail: @mail)}]
    end

    # A user EHOS runs with, cleared by `--smtp-username ""`: the warning comes through progress,
    # before the install, and the user is gone.
    test "with its kept user cleared, warns of it, and installs it without one", %{opts: opts} do
      runs(recorded("0.7.0"), %{mail: @mail})
      Process.put({Platform, :on_stderr}, true)

      assert ehosctl(["upgrade", "--smtp-username", ""], opts) ==
               {0,
                moved(
                  "0.7.0",
                  "0.10.0",
                  "Its console stays at https://ehos.acme.example.org. It sends mail from " <>
                    "ehos@example.com through smtp.example.com:587."
                ), @no_user_warning <> "[installed]\n"}

      assert said() == [{:server, install(opts, "trial", "0.10.0", mail: @no_user)}]
    end

    test "given to the version that runs, names it in the command that installs it",
         %{opts: opts} do
      runs(recorded("0.10.0"))

      assert ehosctl(~w(upgrade --smtp-host smtp.example.com --mail-from ehos@example.com), opts) ==
               {0,
                "trial runs EHOS 0.10.0 already. Nothing was changed, so the mail settings were " <>
                  "not applied either; `ehosctl install --installation trial --version 0.10.0 " <>
                  "--mail-from ehos@example.com --smtp-host smtp.example.com` installs it " <>
                  "again.\n", ""}

      assert said() == []

      runs(recorded("0.10.0"))
      stub_env(Map.put(@env, "SMTP_PASSWORD", "pw"))

      argv = [
        "upgrade",
        "--smtp-host",
        "smtp.example.com",
        "--smtp-username",
        "ehos",
        "--mail-from",
        "o'brien@example.com"
      ]

      # Quoted as a POSIX shell reads it, so the command can be pasted.
      assert ehosctl(argv, opts) ==
               {0,
                "trial runs EHOS 0.10.0 already. Nothing was changed, so the mail settings were " <>
                  "not applied either, and SMTP_PASSWORD was not written; `ehosctl install " <>
                  "--installation trial --version 0.10.0 " <>
                  ~S(--mail-from 'o'\''brien@example.com') <>
                  " --smtp-host smtp.example.com --smtp-username ehos` installs it again.\n", ""}

      # On the version that runs, the answer is the install command, not a refusal it would make.
      runs(recorded("0.10.0"), %{mail: @mail})
      stub_env(Map.delete(@env, "SMTP_PASSWORD"))

      assert ehosctl(~w(upgrade --smtp-username bob), opts) ==
               {0,
                "trial runs EHOS 0.10.0 already. Nothing was changed, so the mail settings were " <>
                  "not applied either; `ehosctl install --installation trial --version 0.10.0 " <>
                  "--smtp-username bob` installs it again.\n", ""}

      assert said() == []
    end
  end

  # The questions asked and the installs run, in the order they came, each install with what it
  # was given but its progress, a function.
  defp said do
    receive do
      {:asked, question} -> [{:asked, question} | said()]
      {:server, server} -> [{:server, Keyword.delete(server, :progress)} | said()]
    after
      0 -> []
    end
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

  # What `EhosPlatform.Install` is given to install `version` on `name`, as the setup's servers
  # and options leave it, with `fields` in place of what they would be.
  defp install(opts, name, version, fields \\ []) do
    Enum.reduce(
      fields,
      [
        name: name,
        home: opts[:home],
        runner: Ehosctl.PlatformRunner,
        server_command: "ehosctl server",
        name_option: "--installation",
        name_in_commands: true,
        source: %EhosPlatform.Source{chart: {:oci, chart(version)}, modules: nil},
        digest: digest(version),
        installed: recorded(version),
        host: @host,
        sign_in: nil,
        four_eyes: nil,
        mail: nil,
        smtp_password: nil,
        token: "ghp_token",
        username: nil,
        passphrase: "a passphrase of 16+",
        switch_traefik: false,
        ssh_key: nil
      ],
      fn {key, value}, install -> Keyword.replace!(install, key, value) end
    )
  end

  # The question asked before a move to `target` past `version`, which migrates.
  defp migrates(version, target),
    do:
      "EHOS #{version} changes the governance database, or does not say whether it does. EHOS " <>
        "keeps no backup of that database: once changed, it cannot go back. Move to " <>
        "#{target}? [y/N] "

  defp unrecorded(target),
    do:
      "Moving to #{target} may change the governance database, and EHOS keeps no backup of it " <>
        "to go back to. Go on? [y/N] "

  defp not_recorded(why),
    do:
      "ehosctl: trial runs an EHOS whose version nothing recorded, and #{why}, so ehosctl " <>
        "cannot tell whether 0.7.0 is newer: it may be a build of a later commit. Give " <>
        "--allow-unrecorded to move it to 0.7.0 anyway. Nothing was changed.\n"

  # A release's notes as `upgrade` prints them.
  defp note(version, body \\ nil) do
    """
    # ehos #{version} (2026-10-09)
    https://github.com/EmpoweredHouse/eh-os/releases/tag/v#{version}

    #{body || "What #{version} changed."}\
    """
  end

  # What a move of trial from `from` to `to` prints, with one release on the way, `said` about
  # what it keeps.
  defp moved(from, to, said) do
    """
    trial runs EHOS #{from}; moving it to #{to}.
    #{said}

    #{note(to)}
    """ <> @installed_trial
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
end
