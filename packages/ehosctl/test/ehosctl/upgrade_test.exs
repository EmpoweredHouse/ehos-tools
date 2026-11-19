defmodule Ehosctl.UpgradeTest do
  # Not async: capture_io(:stderr) captures stderr for every process.
  use Ehosctl.Case, async: false

  alias Ehosctl.FakeGitHub
  alias Ehosctl.FakeHTTP

  @moduletag :tmp_dir

  @env %{"GHCR_TOKEN" => "ghp_token", "EHOS_STATE_PASSPHRASE" => "a passphrase of 16+"}

  @host "ehos.acme.example.org"

  # A database outside the installation, as the running release lists it (eh-os D-170).
  @external %{
    "name" => "ledger",
    "version" => 17,
    "host" => "ledger.db.example.com",
    "port" => 5432,
    "database" => "ledger",
    "ca" => "-----BEGIN CERTIFICATE-----\n",
    "addressRanges" => ["10.20.0.0/24"],
    "managingRoleSecret" => "ehos-external-ledger"
  }

  @mail %{
    "from" => "ehos@example.com",
    "smtp" => %{"host" => "smtp.example.com", "port" => 587, "username" => "ehos"}
  }

  @no_user %{
    "from" => "ehos@example.com",
    "smtp" => %{"host" => "smtp.example.com", "port" => 587}
  }

  # eh-os D-141: a relay that admits the server by its address admits every application on it.
  @no_user_warning "! EHOS sends mail through smtp.example.com:587 with no SMTP user.\n" <>
                     "  If the relay admits the server by its address, it admits each " <>
                     "application on the server. An application that names smtp.example.com " <>
                     "under needs.egress can then send as anyone in the domain of the " <>
                     "company, outside its mail agreement. If applications of others run " <>
                     "here, give EHOS a user of the relay (--smtp-username, with " <>
                     "SMTP_PASSWORD). Then make the relay require that user, not the address " <>
                     "of the server.\n"

  # What a move says it keeps, as the setup's EHOS runs: its console, and no mail; and with four
  # eyes off.
  @console_alone "The console stays at https://ehos.acme.example.org. EHOS sends no mail."
  @self_approval "The console stays at https://ehos.acme.example.org. The person who deployed " <>
                   "or asked for a promotion can approve it, without a second person. EHOS " <>
                   "sends no mail."

  @installed_trial """
  ✓ EHOS is running at https://ehos.acme.example.org.

  Next:
    ehosctl login --installation trial
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
      {:ok, %EhosPlatform.Report{outcome: "EHOS is running at https://ehos.acme.example.org."}}
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
                acme runs EHOS 0.5.0. ehosctl moves it to 0.7.0.
                The console stays at https://ehos.acme.example.org. EHOS sends no mail.

                #{note("0.7.0")}

                #{note("0.6.0")}
                ✓ EHOS is running at https://ehos.acme.example.org.

                Next:
                  ehosctl login --installation acme
                """, ""}

      assert_received {:installed, installed}

      assert installed == [
               name: "acme",
               home: opts[:home],
               runner: Ehosctl.PlatformRunner,
               server_command: "ehosctl server",
               release_option: "--version",
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
                trial runs EHOS 0.5.0. ehosctl moves it to 0.7.0.
                The console stays at https://ehos.acme.example.org. EHOS sends mail from ehos@example.com through smtp.example.com:587.

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
                "ehosctl: EHOS on trial serves its console at ehos.192-0-2-1.sslip.io, " <>
                  "which names 192.0.2.1, but the server is at 198.51.100.9 now. To move " <>
                  "the console and the address of each application, give --host " <>
                  "ehos.198-51-100-9.sslip.io. ehosctl changed nothing.\n"}

      assert said() == []

      # `upgrade` moves the host itself, which an EHOS whose version nothing recorded needs:
      # `install` refuses it.
      assert ehosctl(~w(upgrade --yes --host ehos.198-51-100-9.sslip.io), opts) ==
               {0,
                """
                trial runs EHOS 0.9.0. ehosctl moves it to 0.10.0.
                The console stays at https://ehos.198-51-100-9.sslip.io. EHOS sends no mail.

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
                trial runs EHOS 0.5.0. ehosctl moves it to 0.7.0.
                The console stays at https://ehos.acme.example.org. EHOS sends no mail.

                #{note("0.7.0")}

                #{note("0.6.0")}
                """ <> @installed_trial, ""}

      assert said() == [{:server, install(opts, "trial", "0.7.0")}]

      runs(recorded("0.6.0"))

      assert ehosctl(~w(upgrade), opts) ==
               {0,
                """
                trial runs EHOS 0.6.0. ehosctl moves it to 0.7.0.
                The console stays at https://ehos.acme.example.org. EHOS sends no mail.

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
                trial runs EHOS 0.6.0. ehosctl moves it to 0.7.0.
                The console stays at https://ehos.acme.example.org. EHOS sends no mail.

                #{note("0.7.0")}
                · ehosctl changed nothing.
                """, ""}

      assert said() == [{:asked, migrates("0.7.0", "0.7.0")}]
    end

    test "moves to the release --to names, and refuses one EHOS does not have", %{opts: opts} do
      Process.put(:answer, true)

      assert ehosctl(~w(upgrade --to 0.6.0), opts) ==
               {0,
                """
                trial runs EHOS 0.5.0. ehosctl moves it to 0.6.0.
                The console stays at https://ehos.acme.example.org. EHOS sends no mail.

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
                "ehosctl: trial runs EHOS 0.7.0, and 0.5.0 is older. Migrations do not " <>
                  "run backwards, so the code of 0.5.0 meets the database that 0.7.0 left. " <>
                  "Give --allow-downgrade to move down anyway. ehosctl changed nothing.\n"}

      assert said() == []

      Process.put(:answer, true)

      assert ehosctl(~w(upgrade --to 0.5.0 --allow-downgrade), opts) ==
               {0,
                """
                trial runs EHOS 0.7.0. ehosctl moves it down to 0.5.0.
                The console stays at https://ehos.acme.example.org. EHOS sends no mail.

                #{note("0.7.0")}

                #{note("0.6.0")}
                """ <> @installed_trial, ""}

      assert said() == [
               {:asked,
                "EHOS 0.5.0 will run on the governance database as 0.7.0 left it, and " <>
                  "possibly cannot read it. EHOS keeps no backup of the database. Move " <>
                  "down to 0.5.0? [y/N] "},
               {:server, install(opts, "trial", "0.5.0")}
             ]
    end

    test "changes nothing for the version that runs, and refuses it when its release changed", %{
      opts: opts
    } do
      runs(recorded("0.7.0"))

      assert ehosctl(~w(upgrade), opts) ==
               {0, already("0.7.0"), ""}

      assert said() == []

      runs(%{recorded("0.7.0") | "image" => image("0.1.0")})

      assert ehosctl(~w(upgrade), opts) ==
               {1, "",
                "ehosctl: trial runs EHOS 0.7.0 as #{image("0.1.0")}, from #{chart("0.7.0")}, " <>
                  "but its release now names #{image("0.7.0")}, from #{chart("0.7.0")}. Nobody changes a release after it is published. " <>
                  "Find out who changed it before you install anything from it. ehosctl " <>
                  "changed nothing.\n"}

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
                trial runs EHOS 0.6.0. ehosctl moves it to 0.7.0.
                The console stays at https://ehos.acme.example.org. EHOS sends no mail.

                #{note("0.7.0", "ehosctl cannot read the notes of this release. https://api.github.com answered with more than 2097152 bytes, more than ehosctl reads from it.")}
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
                "ehosctl: trial runs an EHOS whose version nobody recorded, and ehosctl " <>
                  "could not read each release to find the release of its image (v0.6.0: " <>
                  "The release.json of v0.6.0 is not a JSON object.). So ehosctl cannot " <>
                  "tell if 0.7.0 is newer: the EHOS that runs can be a build of a later " <>
                  "commit. Give --allow-unrecorded to move it to 0.7.0 anyway. ehosctl " <>
                  "changed nothing.\n"}

      assert said() == []

      # Which --allow-unrecorded then gets past, after the question.
      Process.put(:answer, true)

      assert ehosctl(~w(upgrade --allow-unrecorded), opts) ==
               {0,
                """
                trial runs an EHOS whose version nobody recorded. ehosctl moves it to 0.7.0.
                The console stays at https://ehos.acme.example.org. EHOS sends no mail.

                #{note("0.7.0")}
                """ <> @installed_trial, ""}

      assert said() == [
               {:asked, unrecorded("0.7.0")},
               {:server, install(opts, "trial", "0.7.0")}
             ]

      runs(:unknown, %{digest: nil})

      assert ehosctl(~w(upgrade), opts) ==
               {2, "", not_recorded("ehosctl could not read the digest of its image")}
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
                trial runs EHOS 0.5.0. ehosctl moves it to 0.7.0.
                The console stays at https://ehos.acme.example.org. EHOS sends no mail.

                #{note("0.7.0")}

                #{note("0.6.0", "Notes of v0.6.0.")}
                · ehosctl changed nothing.
                """, ""}

      assert said() == [
               {:asked,
                "ehosctl could not read the release.json of EHOS 0.6.0 to see if it changes " <>
                  "the governance database. EHOS keeps no backup of that database: after a " <>
                  "change, you cannot go back. Move to 0.7.0? [y/N] "}
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
                trial runs EHOS 1.0.0. ehosctl moves it to 1.0.52.
                The console stays at https://ehos.acme.example.org. EHOS sends no mail.

                #{Enum.map_join(52..3//-1, "\n\n", &note("1.0.#{&1}"))}

                ehosctl leaves out 2 older releases. The notes are at https://github.com/EmpoweredHouse/eh-os/releases.
                · ehosctl changed nothing.
                """, ""}

      assert said() == [
               {:asked,
                "ehosctl did not read 2 older releases on the way, which can change the " <>
                  "governance database. EHOS keeps no backup of that database: after a change, " <>
                  "you cannot go back. Move to 1.0.52? [y/N] "}
             ]
    end

    test "takes over an EHOS that recorded nothing by its image's digest", %{opts: opts} do
      Process.put(:answer, true)
      runs(:unknown, %{digest: digest("0.6.0")})

      assert ehosctl(~w(upgrade), opts) ==
               {0,
                """
                trial runs EHOS 0.6.0, by the digest of its image. ehosctl moves it to 0.7.0.
                The console stays at https://ehos.acme.example.org. EHOS sends no mail.

                #{note("0.7.0")}
                """ <> @installed_trial, ""}

      assert said() == [{:server, install(opts, "trial", "0.7.0")}]

      # Matched to the target itself, it is installed again from its release, which records it.
      # Nothing on the way, so no notes: the heading alone.
      runs(:unknown, %{digest: digest("0.7.0")})

      assert ehosctl(~w(upgrade), opts) ==
               {0,
                """
                trial runs EHOS 0.7.0, by the digest of its image, but nothing recorded its version. ehosctl installs it again from its release, which records the version.
                The console stays at https://ehos.acme.example.org. EHOS sends no mail.
                """ <> @installed_trial, ""}

      assert said() == [{:server, install(opts, "trial", "0.7.0")}]
    end

    test "moves an EHOS no release's image matches only with --allow-unrecorded, after asking", %{
      opts: opts
    } do
      for {digest, why} <- [
            {digest("0.1.0"), "its image is in no release"},
            {nil, "ehosctl could not read the digest of its image"}
          ] do
        runs(:unknown, %{digest: digest})
        assert ehosctl(~w(upgrade), opts) == {2, "", not_recorded(why)}
        assert said() == []
      end

      Process.put(:answer, true)

      assert ehosctl(~w(upgrade --allow-unrecorded), opts) ==
               {0,
                """
                trial runs an EHOS whose version nobody recorded. ehosctl moves it to 0.7.0.
                The console stays at https://ehos.acme.example.org. EHOS sends no mail.

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
                trial runs EHOS 0.6.0. ehosctl moves it to 0.7.0.
                The console stays at https://ehos.acme.example.org. EHOS sends no mail.

                #{note("0.7.0")}
                """ <> @installed_trial,
                "! The last attempt, revision 3 of Helm, failed (timed out waiting).\n"}

      assert said() == [{:server, install(opts, "trial", "0.7.0")}]
    end

    test "says in its help that it is on the platform plane", %{opts: opts} do
      assert ehosctl(~w(upgrade --help), opts) ==
               {0,
                """
                ehosctl #{Ehosctl.version()}
                Move EHOS on the server of an installation to another release, through the tunnel to the server. ehosctl shows the release notes first. Needs GHCR_TOKEN, and SMTP_PASSWORD for a user of an SMTP server.

                USAGE:
                    ehosctl upgrade [--allow-downgrade] [--allow-unrecorded] [--yes] [--four-eyes] [--no-four-eyes] [--no-mail] [--switch-traefik] [--no-allowed-domains] [--installation NAME] [--to V] [--host HOST] [--sign-in-absolute DURATION] [--sign-in-idle DURATION] [--smtp-host HOST] [--smtp-port PORT] [--smtp-username USER] [--mail-from ADDRESS] [--ssh-key PATH] [--allowed-domain DOMAIN]

                FLAGS:

                    --allow-downgrade           Also move to a lower version. Migrations do not
                                                run backwards: the older code meets the database
                                                that the newer code left.
                    --allow-unrecorded          Move an EHOS whose version nobody recorded and
                                                whose image matches no release, as `mix
                                                ehos.install` can leave it.
                    --yes                       Do not ask for confirmation.
                    --four-eyes                 Turn on four eyes: a second person approves each
                                                promotion to production, not the person who
                                                deployed the candidate or asked. A new EHOS
                                                0.14.0 or later starts without four eyes.
                    --no-four-eyes              Let the person who deployed or asked approve
                                                their own promotion. EHOS records it as a
                                                self-approval. For an installation of one
                                                person. Later upgrades keep it.
                    --no-mail                   Stop the mail of EHOS: EHOS forgets its SMTP
                                                server. The password stays in the cluster.
                    --switch-traefik            Replace the Traefik of k3s with the Traefik of
                                                EHOS, on a server made before EHOS 0.15.0. k3s
                                                restarts, and the console and its applications
                                                stop for a few minutes. Without this flag,
                                                ehosctl refuses such a server. Needs
                                                EHOS_STATE_PASSPHRASE.
                    --no-allowed-domains        Remove all allowed domains. Remove each mapped
                                                domain first: EHOS refuses a route for a domain
                                                that is not allowed.

                OPTIONS:

                    --installation            The installation of the server. By default
                                              EHOSCTL_INSTALLATION, else the current
                                              installation, else trial.
                    --to                      The release of EHOS to move to. By default the
                                              newest release.
                    --host                    The host of the console. By default the host that
                                              EHOS serves now. The address of each application
                                              follows it.
                    --sign-in-absolute        How long a sign-in of a person to an application
                                              lasts after the person signs in at EHOS. Format:
                                              hours or days, such as 12h or 30d, at most 366d.
                                              By default the value that EHOS uses now, else 12h.
                    --sign-in-idle            How long such a sign-in lasts when the person does
                                              not use it, at most the absolute limit. Format:
                                              hours or days. By default the value that EHOS uses
                                              now, else 1h.
                    --smtp-host               The SMTP server that EHOS sends mail through, such
                                              as invitations. By default the server that EHOS
                                              uses now, else none. TLS is always on and
                                              verified.
                    --smtp-port               The port of the SMTP server: 587 for STARTTLS (the
                                              default), or 465 for TLS from the first byte.
                    --smtp-username           The user that EHOS signs in to the SMTP server as,
                                              with SMTP_PASSWORD. By default the user that EHOS
                                              uses now. Give "" for none.
                    --mail-from               The address that EHOS sends mail from. EHOS needs
                                              it with an SMTP server.
                    --ssh-key                 The private key that made the server, for
                                              --switch-traefik. By default the key that `ehosctl
                                              server up` recorded, else ~/.ssh/ehos_oci.
                    --allowed-domain          A domain of your company, such as client.example.
                                              A person can then map it, or a name under it, to
                                              an application in production. Give it once for
                                              each domain; the list replaces the list that EHOS
                                              has. By default EHOS keeps its list. Needs public
                                              certificates. Format: lowercase, as an A-label,
                                              never on the Public Suffix List.

                Plane: platform. This command acts with an account that EHOS does not issue: an account of a cloud provider, an SSH key or a kubeconfig.

                """, ""}
    end

    test "changes nothing when the question is not answered yes", %{opts: opts} do
      assert ehosctl(~w(upgrade), opts) ==
               {0,
                """
                trial runs EHOS 0.5.0. ehosctl moves it to 0.7.0.
                The console stays at https://ehos.acme.example.org. EHOS sends no mail.

                #{note("0.7.0")}

                #{note("0.6.0")}
                · ehosctl changed nothing.
                """, ""}

      assert said() == [{:asked, migrates("0.6.0", "0.7.0")}]
    end

    test "says nothing is installed before it asks GitHub", %{github: github, opts: opts} do
      FakeHTTP.down(github)
      runs(:none)

      assert ehosctl(~w(upgrade), opts) ==
               {2, "",
                "ehosctl: trial runs no EHOS to upgrade. To install EHOS, run " <>
                  "`ehosctl install --installation trial`.\n"}
    end

    test "refuses where nothing is installed, or under a revision still pending", %{opts: opts} do
      runs(:none)

      assert ehosctl(~w(upgrade), opts) ==
               {2, "",
                "ehosctl: trial runs no EHOS to upgrade. To install EHOS, run " <>
                  "`ehosctl install --installation trial`.\n"}

      runs(recorded("0.5.0"), %{
        last: %{revision: 7, status: "pending-upgrade", description: "Preparing upgrade"}
      })

      helm = "helm --kubeconfig #{opts[:home]}/trial/kubeconfig --kube-context ehos-trial"

      assert ehosctl(~w(upgrade), opts) ==
               {1, "",
                "ehosctl: The last change to EHOS on trial, revision 7 of Helm, is " <>
                  "pending-upgrade (Preparing upgrade). An install or upgrade is running, or one " <>
                  "stopped before it ended. Wait for it to end. If it stopped, `#{helm} -n " <>
                  "ehos-system history ehos` shows the revisions. Run `#{helm} -n ehos-system " <>
                  "rollback ehos REVISION`, with the last deployed revision, to end it. Then run this command " <>
                  "again. ehosctl changed nothing.\n"}

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
                "ehosctl: This computer has no server for the installation ehos-92-5-148-138 " <>
                  "(the current installation). It has servers for the installations acme, " <>
                  "trial. Run the command again with --installation and one of them.\n"}

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
                  "The console stays at https://ehos.acme.example.org. A sign-in to an " <>
                    "application lasts 30d, and 14d when the person does not use it. EHOS sends no mail."
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
                  "The console stays at https://ehos.acme.example.org. A sign-in to an " <>
                    "application lasts 30d, and 2d when the person does not use it. EHOS sends no mail."
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
               {0, already("0.10.0", " --sign-in-absolute 30d --sign-in-idle 14d"),
                not_applied("the sign-in limits")}

      assert said() == []
    end

    test "sends them to no EHOS before 0.10.0, and does not say them", %{opts: opts} do
      runs(recorded("0.10.0"), %{sign_in: %{"absolute" => "30d"}})

      assert ehosctl(~w(upgrade --to 0.7.0 --allow-downgrade --yes), opts) ==
               {0,
                """
                trial runs EHOS 0.10.0. ehosctl moves it down to 0.7.0.
                The console stays at https://ehos.acme.example.org. EHOS sends no mail.

                #{note("0.10.0")}
                """ <> @installed_trial, ""}

      assert said() == [{:server, install(opts, "trial", "0.7.0")}]
    end

    test "refuses them as the chart would refuse them, before anything changes", %{opts: opts} do
      runs(recorded("0.7.0"), %{sign_in: %{"absolute" => "30d"}})

      assert ehosctl(~w(upgrade --sign-in-idle 31d), opts) ==
               {2, "",
                "ehosctl: --sign-in-idle (31d) must be at most the absolute limit that " <>
                  "EHOS uses now (30d). Give a shorter --sign-in-idle or a longer " <>
                  "--sign-in-absolute.\n"}

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
               {0, already("0.10.0", " --sign-in-absolute 30d --no-four-eyes"),
                not_applied("the sign-in limits and the four-eyes setting")}

      assert said() == []

      assert ehosctl(~w(upgrade --no-four-eyes), opts) ==
               {0, already("0.10.0", " --no-four-eyes"), not_applied("the four-eyes setting")}

      argv = ~w(upgrade --sign-in-idle 1h --four-eyes --smtp-host h.example.com --mail-from a@b.c)

      assert ehosctl(argv, opts) ==
               {0,
                already(
                  "0.10.0",
                  " --sign-in-idle 1h --four-eyes --mail-from a@b.c --smtp-host h.example.com"
                ), not_applied("the sign-in limits, the four-eyes setting and the mail settings")}
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
                trial runs EHOS 0.12.0. ehosctl moves it to 0.13.0.
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
                trial runs EHOS 0.9.0. ehosctl moves it down to 0.8.0.
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
                  "The console stays at https://ehos.acme.example.org. EHOS sends mail from " <>
                    "ehos@example.com through smtp.example.com:587 as ehos."
                ), ""}

      assert said() == [{:server, install(opts, "trial", "0.10.0", mail: @mail)}]

      runs(recorded("0.7.0"), %{mail: @mail})

      assert ehosctl(~w(upgrade --mail-from team@example.com), opts) ==
               {0,
                moved(
                  "0.7.0",
                  "0.10.0",
                  "The console stays at https://ehos.acme.example.org. EHOS sends mail from " <>
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
                  "The console stays at https://ehos.acme.example.org. EHOS sends mail from " <>
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
                  "The console stays at https://ehos.acme.example.org. EHOS sends mail from " <>
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
                  "The console stays at https://ehos.acme.example.org. EHOS sends mail from " <>
                    "ehos@example.com through smtp.example.com:587."
                ), @no_user_warning <> "[installed]\n"}

      assert said() == [{:server, install(opts, "trial", "0.10.0", mail: @no_user)}]
    end

    test "given to the version that runs, names it in the command that installs it",
         %{opts: opts} do
      runs(recorded("0.10.0"))

      assert ehosctl(~w(upgrade --smtp-host smtp.example.com --mail-from ehos@example.com), opts) ==
               {0,
                already("0.10.0", " --mail-from ehos@example.com --smtp-host smtp.example.com"),
                not_applied("the mail settings")}

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
                already(
                  "0.10.0",
                  ~S( --mail-from 'o'\''brien@example.com') <>
                    " --smtp-host smtp.example.com --smtp-username ehos"
                ), not_applied("the mail settings") <> "! ehosctl did not write SMTP_PASSWORD.\n"}

      # On the version that runs, the answer is the install command, not a refusal it would make.
      runs(recorded("0.10.0"), %{mail: @mail})
      stub_env(Map.delete(@env, "SMTP_PASSWORD"))

      assert ehosctl(~w(upgrade --smtp-username bob), opts) ==
               {0, already("0.10.0", " --smtp-username bob"), not_applied("the mail settings")}

      assert said() == []
    end
  end

  # What `upgrade` says on the version `version` that runs: nothing changed, and the command that
  # installs it again with `options`.
  defp already(version, options \\ ""),
    do:
      "· trial runs EHOS #{version} already. ehosctl changed nothing.\n\nNext:\n" <>
        "  ehosctl install --installation trial --version #{version}#{options}\n"

  # The warning of the settings `what` given to the version that runs, which it did not apply.
  defp not_applied(what),
    do:
      "! ehosctl did not apply #{what}.\n" <>
        "  To apply them, install the version that runs again, with the command under Next.\n"

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

  # eh-os D-155, ehos-tools#853: Helm would otherwise empty the list on the upgrade.
  describe "upgrade's allowed domains" do
    setup %{github: github} do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [
        release("0.27.0", %{"migrates" => false}),
        release("0.26.0", %{"migrates" => false})
      ])

      :ok
    end

    test "keeps the domains the running EHOS allows", %{opts: opts} do
      runs(recorded("0.26.0"), %{allowed_domains: ["client.example"]})

      assert {0, moved, ""} = ehosctl(~w(upgrade), opts)
      refute moved =~ "A person can map"

      assert said() == [
               {:server, install(opts, "trial", "0.27.0", allowed_domains: ["client.example"])}
             ]
    end

    # ehos-tools#902: `install` refuses another version than the one that runs.
    test "replaces the list with the domains given, or empties it", %{opts: opts} do
      runs(recorded("0.26.0"), %{allowed_domains: ["legacy.example"]})

      assert {0, moved, ""} =
               ehosctl(
                 ~w(upgrade --allowed-domain client.example --allowed-domain other.example),
                 opts
               )

      assert moved =~
               " A person can map client.example and other.example, or a name under them, and " <>
                 "no other domain."

      assert said() == [
               {:server,
                install(opts, "trial", "0.27.0",
                  allowed_domains: ["client.example", "other.example"]
                )}
             ]

      runs(recorded("0.26.0"), %{allowed_domains: ["client.example"]})
      assert {0, moved, ""} = ehosctl(~w(upgrade --no-allowed-domains), opts)
      assert moved =~ " A person can map no domain of your company: EHOS allows none."
      assert said() == [{:server, install(opts, "trial", "0.27.0", allowed_domains: [])}]
    end

    test "given to the version that runs, names them in the command that installs them",
         %{opts: opts} do
      runs(recorded("0.27.0"), %{allowed_domains: ["client.example"]})

      assert ehosctl(~w(upgrade --allowed-domain other.example), opts) ==
               {0, already("0.27.0", " --allowed-domain other.example"),
                not_applied("the allowed domains")}

      assert said() == []

      # Quoted as a shell word, so the command runs as given.
      assert {0, text, _not_applied} = ehosctl(["upgrade", "--allowed-domain", "a b"], opts)
      assert text =~ "--allowed-domain 'a b'\n"
    end
  end

  # eh-os D-170, T-29: Helm would otherwise drop the list on the upgrade.
  describe "upgrade's databases outside the installation" do
    setup %{github: github} do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [
        release("0.31.0", %{"migrates" => false}),
        release("0.30.0", %{"migrates" => false}),
        release("0.29.0", %{"migrates" => false})
      ])

      :ok
    end

    test "writes the list of the running EHOS and its development flag again", %{opts: opts} do
      runs(recorded("0.30.0"), %{
        external_databases: [@external],
        external_under_development: true
      })

      assert {0, _moved, ""} = ehosctl(~w(upgrade), opts)

      assert said() == [
               {:server,
                install(opts, "trial", "0.31.0",
                  external_databases: [@external],
                  external_under_development: true
                )}
             ]
    end

    test "refuses a move to an EHOS before 0.30.0 while the running EHOS lists a database", %{
      opts: opts
    } do
      runs(recorded("0.30.0"), %{
        external_databases: [@external, %{@external | "name" => "audit"}],
        external_under_development: true
      })

      assert ehosctl(~w(upgrade --to 0.29.0 --allow-downgrade --yes), opts) ==
               {2, "",
                "ehosctl: EHOS 0.29.0 cannot use a database outside the installation, and the " <>
                  "EHOS that runs uses ledger and audit. Databases outside the installation " <>
                  "start in 0.30.0. Install 0.30.0 or later. ehosctl changed nothing.\n"}

      assert said() == []
    end

    test "names each database it refuses for as a name, never as raw text", %{opts: opts} do
      runs(recorded("0.30.0"), %{external_databases: [%{@external | "name" => "led\e[2Jger"}]})

      assert {2, "", stderr} = ehosctl(~w(upgrade --to 0.29.0 --allow-downgrade --yes), opts)
      refute stderr =~ "\e"
      assert stderr =~ ~S(uses "led\e[2Jger".)
    end

    test "sends no list to an EHOS before 0.30.0 when the running EHOS lists none", %{
      opts: opts
    } do
      runs(recorded("0.5.0"), %{external_under_development: false})

      assert {0, _moved, ""} = ehosctl(~w(upgrade --to 0.29.0), opts)
      assert said() == [{:server, install(opts, "trial", "0.29.0")}]
    end

    test "says each database it leaves out of the list before it installs", %{opts: opts} do
      warning =
        "The database outside the installation other keeps its managing role in the Secret " <>
          "other-admin, and the installer keeps only ehos-external-other."

      runs(recorded("0.30.0"), %{warnings: [warning]})
      Process.put({Platform, :on_stderr}, true)

      assert {0, _moved, stderr} = ehosctl(~w(upgrade), opts)
      assert stderr == "! " <> warning <> "\n[installed]\n"
    end
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
             allowed_domains: nil,
             external_databases: nil,
             external_under_development: nil,
             warnings: [],
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
        release_option: "--version",
        name_option: "--installation",
        name_in_commands: true,
        source: %EhosPlatform.Source{chart: {:oci, chart(version)}, modules: nil},
        digest: digest(version),
        installed: recorded(version),
        host: @host,
        sign_in: nil,
        four_eyes: nil,
        mail: nil,
        allowed_domains: nil,
        external_databases: nil,
        external_under_development: nil,
        smtp_password: nil,
        token: "ghp_token",
        username: nil,
        passphrase: "a passphrase of 16+",
        switch_traefik: false,
        public_certificates: false,
        skip_port_53_check: false,
        ssh_key: nil
      ],
      fn {key, value}, install -> Keyword.replace!(install, key, value) end
    )
  end

  # The question asked before a move to `target` past `version`, which migrates.
  defp migrates(version, target),
    do:
      "EHOS #{version} changes the governance database, or does not say if it does. EHOS " <>
        "keeps no backup of that database: after a change, you cannot go back. Move to " <>
        "#{target}? [y/N] "

  defp unrecorded(target),
    do:
      "The move to #{target} can change the governance database, and EHOS keeps no backup " <>
        "of it. Continue? [y/N] "

  defp not_recorded(why),
    do:
      "ehosctl: trial runs an EHOS whose version nobody recorded, and #{why}. So ehosctl " <>
        "cannot tell if 0.7.0 is newer: the EHOS that runs can be a build of a later commit. " <>
        "Give --allow-unrecorded to move it to 0.7.0 anyway. ehosctl changed nothing.\n"

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
    trial runs EHOS #{from}. ehosctl moves it to #{to}.
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
