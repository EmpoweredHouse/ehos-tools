defmodule Ehosctl.InstallTest do
  # Not async: capture_io(:stderr) captures stderr for every process.
  use Ehosctl.Case, async: false

  alias Ehosctl.Config
  alias Ehosctl.FakeGitHub
  alias Ehosctl.FakeHTTP

  @moduletag :tmp_dir

  @env %{"GHCR_TOKEN" => "ghp_token", "EHOS_STATE_PASSPHRASE" => "a passphrase of 16+"}
  @image "ghcr.io/empoweredhouse/ehos@sha256:" <> String.duplicate("b", 64)
  @chart "oci://ghcr.io/empoweredhouse/charts/ehos@sha256:" <> String.duplicate("c", 64)
  @running %{"version" => "0.6.0", "image" => @image, "chart" => @chart}
  @running_0_10 %{"version" => "0.10.0", "image" => @image, "chart" => @chart}
  @smtp ~w(--smtp-host smtp.example.com --smtp-username ehos --mail-from ehos@example.com)
  @mail %{
    "from" => "ehos@example.com",
    "smtp" => %{"host" => "smtp.example.com", "port" => 587, "username" => "ehos"}
  }
  @running_at "EHOS is running at https://ehos.192-0-2-7.sslip.io.\n"
  @unwritten "ehosctl: EHOS sends mail through settings that ehosctl did not write " <>
               "(governance.mail in its Helm release). Give --smtp-host and --mail-from " <>
               "to replace them, or give --no-mail. ehosctl changed nothing.\n"

  # In place of Run Run `EhosPlatform.Install`: answers what runs as the test puts it, and on an install
  # says what it was asked and writes what the real one leaves beside the installation.
  defmodule Platform do
    @moduledoc false

    def installed(opts) do
      send(self(), {:installed, opts})

      Process.get(
        {__MODULE__, :installed},
        {:ok,
         %{
           running: :none,
           digest: nil,
           host: nil,
           sign_in: nil,
           four_eyes: nil,
           mail: nil,
           last: nil
         }}
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

  setup %{tmp_dir: dir} do
    github = FakeGitHub.start()
    %{cert: der} = :public_key.pkix_test_root_cert(~c"EHOS CA", [])
    Process.put({Platform, :ca}, :public_key.pem_encode([{:Certificate, der, :not_encrypted}]))

    opts =
      [
        install: Platform,
        home: Path.join(dir, "ehos"),
        config_dir: Path.join(dir, "config")
      ]

    stub_env(@env)

    # The servers these tests install on: their state, as `ehosctl server up` leaves it.
    for name <- ~w(trial acme) do
      File.mkdir_p!(Path.join(opts[:home], name))
      File.write!(Path.join([opts[:home], name, "server.tfvars.json"]), "{}")
      File.write!(Path.join([opts[:home], name, "installation.json"]), ~s({"provider": "oci"}))
    end

    FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [release("0.6.0"), release("0.5.0")])
    %{github: github, opts: opts}
  end

  describe "install" do
    test "installs the newest release by its digests, records it, and keeps the installation for login",
         %{opts: opts} do
      assert ehosctl(~w(install --installation acme), opts) == {0, installed("acme"), ""}

      assert_received {:installed, installed}
      assert installed == base(opts, "acme")

      # eh-os#823: a server running k3s's Traefik is switched only when asked, over SSH.
      assert_server(opts, %{name: "acme"})

      {:ok, config} = Config.read(opts[:config_dir])

      assert config == %Config{
               current: nil,
               installations: %{
                 "acme" => %{
                   "url" => "https://ehos.192-0-2-7.sslip.io",
                   "ca" => Process.get({Platform, :ca})
                 }
               }
             }
    end

    test "keeps an installation another command added while it waited for config.json",
         %{opts: opts} do
      dev = Config.put(%Config{}, "dev", "https://ehos.dev.example.com")
      holder = change_config_while_locked(opts[:config_dir], fn -> dev end)

      assert ehosctl(~w(install --installation acme), opts) == {0, installed("acme"), ""}
      assert Task.await(holder) == :ok

      {:ok, config} = Config.read(opts[:config_dir])

      assert config == %Config{
               current: nil,
               installations: %{
                 "dev" => %{"url" => "https://ehos.dev.example.com"},
                 "acme" => %{
                   "url" => "https://ehos.192-0-2-7.sslip.io",
                   "ca" => Process.get({Platform, :ca})
                 }
               }
             }
    end

    test "switches a server that runs k3s's Traefik when asked, with the key given",
         %{opts: opts} do
      {0, _stdout, ""} =
        ehosctl(~w(install --installation acme --switch-traefik --ssh-key /keys/acme), opts)

      assert_server(opts, %{name: "acme", switch_traefik: true, ssh_key: "/keys/acme"})
    end

    test "has the platform name the installation in every command it suggests", %{opts: opts} do
      {0, _stdout, ""} = ehosctl(~w(install), opts)
      assert_received {:installed, installed}
      assert installed == base(opts, "trial")
      assert_server(opts)
    end

    test "gives the platform --host and GHCR_USERNAME", %{opts: opts} do
      stub_env(Map.put(@env, "GHCR_USERNAME", "octocat"))
      {0, _stdout, ""} = ehosctl(~w(install --host ehos.acme.example.org), opts)
      assert_server(opts, %{host: "ehos.acme.example.org", username: "octocat"})
    end

    test "installs the release --version names, and refuses one EHOS does not have", %{opts: opts} do
      {0, _stdout, ""} = ehosctl(~w(install --version 0.5.0), opts)
      assert_server(opts, %{installed: %{@running | "version" => "0.5.0"}})

      assert ehosctl(~w(install --version 0.4.0), opts) ==
               {2, "", "ehosctl: EHOS has no release 0.4.0.\n"}
    end

    test "installs the version that runs again, and refuses another, or other digests", %{
      opts: opts
    } do
      runs(%{running: @running})
      {0, _stdout, ""} = ehosctl(~w(install), opts)
      assert_server(opts)

      runs(%{running: %{@running | "version" => "0.5.0"}})

      assert ehosctl(~w(install), opts) ==
               {2, "",
                "ehosctl: trial runs EHOS 0.5.0. An install does not move it to 0.6.0. " <>
                  "Run `ehosctl upgrade --installation trial --to 0.6.0`. ehosctl changed " <>
                  "nothing.\n"}

      refute_received {:server, _server}

      other = "ghcr.io/empoweredhouse/ehos@sha256:" <> String.duplicate("d", 64)
      runs(%{running: %{@running | "image" => other}})

      assert ehosctl(~w(install), opts) ==
               {1, "",
                "ehosctl: trial runs EHOS 0.6.0 as #{other}, from #{@chart}, but its release " <>
                  "now names #{@image}, from #{@chart}. Nobody changes a release after it is " <>
                  "published. Find out who changed it before you install anything from it. " <>
                  "ehosctl changed nothing.\n"}

      refute_received {:server, _server}
    end

    test "installs after a first attempt that failed, and says so; refuses under one pending", %{
      opts: opts
    } do
      runs(%{last: %{revision: 1, status: "failed", description: "context deadline exceeded"}})

      assert ehosctl(~w(install), opts) ==
               {0,
                "The last attempt, revision 1 of Helm, failed (context deadline exceeded).\n" <>
                  installed("trial"), ""}

      assert_server(opts)

      runs(%{
        running: @running,
        last: %{revision: 4, status: "pending-upgrade", description: "Preparing upgrade"}
      })

      # Quoted: the test's directory, named after it, holds a `;`.
      kubeconfig = "'#{Path.join([opts[:home], "acme", "kubeconfig"])}'"
      helm = "helm --kubeconfig #{kubeconfig} --kube-context ehos-acme -n ehos-system"

      assert ehosctl(~w(install --installation acme), opts) ==
               {1, "",
                "ehosctl: " <>
                  pending(
                    "acme",
                    "revision 4 of Helm, is pending-upgrade (Preparing upgrade)",
                    helm
                  ) <>
                  "Run `#{helm} rollback ehos REVISION`, with the last deployed revision, to end it. Then run " <>
                  "this command again. ehosctl changed nothing.\n"}

      refute_received {:server, _server}

      # A first install interrupted has nothing to roll back to.
      runs(%{
        last: %{revision: 1, status: "pending-install", description: "Initial install underway"}
      })

      assert ehosctl(~w(install --installation acme), opts) ==
               {1, "",
                "ehosctl: " <>
                  pending(
                    "acme",
                    "revision 1 of Helm, is pending-install (Initial install underway)",
                    helm
                  ) <>
                  "Run `#{helm} uninstall ehos` to remove it, because nothing ran before it. Then " <>
                  "run this command again. ehosctl changed nothing.\n"}
    end

    test "installs over a release that was uninstalled, as Helm does", %{opts: opts} do
      runs(%{last: %{revision: 3, status: "uninstalled", description: "Uninstallation complete"}})
      assert ehosctl(~w(install), opts) == {0, installed("trial"), ""}
      assert_server(opts)
    end

    test "keeps the console's host EHOS serves when installed again, unless --host names another",
         %{opts: opts} do
      runs(%{running: @running, host: "ehos.acme.example.org"})

      {0, _stdout, ""} = ehosctl(~w(install), opts)
      assert_server(opts, %{host: "ehos.acme.example.org"})

      {0, _stdout, ""} = ehosctl(~w(install --host ehos.other.example.org), opts)
      assert_server(opts, %{host: "ehos.other.example.org"})
    end

    test "takes the installation of that name to the new address, without its old sign-in", %{
      opts: opts
    } do
      :ok =
        Config.write(
          %Config{
            current: "acme",
            installations: %{
              "acme" => %{
                "url" => "https://ehos.old.example.com",
                "sign_in" => %{"subject" => "s"}
              }
            }
          },
          opts[:config_dir]
        )

      assert ehosctl(~w(install --installation acme), opts) ==
               {0,
                @running_at <>
                  "The installation acme was at https://ehos.old.example.com. It is at " <>
                  "https://ehos.192-0-2-7.sslip.io now.\n" <>
                  "Sign in with `ehosctl login --installation acme`. It trusts the CA of the installation.\n",
                ""}

      # Installed again at the same address, it says nothing of it.
      assert ehosctl(~w(install --installation acme), opts) == {0, installed("acme"), ""}
      {:ok, config} = Config.read(opts[:config_dir])

      assert config == %Config{
               current: "acme",
               installations: %{
                 "acme" => %{
                   "url" => "https://ehos.192-0-2-7.sslip.io",
                   "ca" => Process.get({Platform, :ca})
                 }
               }
             }
    end

    test "says how to sign in when the installation cannot be kept", %{opts: opts, tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "config"))
      File.write!(Path.join([dir, "config", "config.json"]), "{not json")

      assert ehosctl(~w(install --installation acme), opts) ==
               {0,
                @running_at <>
                  "Sign in with `EHOSCTL_CA_FILE=#{dir}/ehos/acme/ca.crt ehosctl login " <>
                  "--installation acme https://ehos.192-0-2-7.sslip.io`. ehosctl could not keep the installation in its configuration.\n",
                ""}
    end

    test "quotes the CA file in how to sign in when the home holds a space", %{
      opts: opts,
      tmp_dir: dir
    } do
      home = Path.join(dir, "Jane Doe")
      File.cp_r!(opts[:home], home)
      File.mkdir_p!(Path.join(dir, "config"))
      File.write!(Path.join([dir, "config", "config.json"]), "{not json")

      assert ehosctl(~w(install --installation acme), Keyword.put(opts, :home, home)) ==
               {0,
                @running_at <>
                  "Sign in with `EHOSCTL_CA_FILE='#{home}/acme/ca.crt' ehosctl login " <>
                  "--installation acme https://ehos.192-0-2-7.sslip.io`. ehosctl could not keep the installation in its configuration.\n",
                ""}
    end

    test "says in its help that it is on the platform plane", %{opts: opts} do
      {0, help, ""} = ehosctl(~w(install --help), opts)

      assert help == """
             ehosctl #{Ehosctl.version()}
             Install a release of EHOS on the server of an installation, through the tunnel to the server. Needs GHCR_TOKEN, and SMTP_PASSWORD for a user of an SMTP server.

             USAGE:
                 ehosctl install [--four-eyes] [--no-four-eyes] [--no-mail] [--switch-traefik] [--installation NAME] [--version V] [--host HOST] [--sign-in-absolute DURATION] [--sign-in-idle DURATION] [--smtp-host HOST] [--smtp-port PORT] [--smtp-username USER] [--mail-from ADDRESS] [--ssh-key PATH]

             FLAGS:

                 --four-eyes             Turn on four eyes: a second person approves each
                                         promotion to production, not the person who deployed
                                         the candidate or asked. A new EHOS 0.14.0 or later
                                         starts without four eyes.
                 --no-four-eyes          Let the person who deployed or asked approve their
                                         own promotion. EHOS records it as a self-approval.
                                         For an installation of one person. Later upgrades
                                         keep it.
                 --no-mail               Stop the mail of EHOS: EHOS forgets its SMTP server.
                                         The password stays in the cluster.
                 --switch-traefik        Replace the Traefik of k3s with the Traefik of EHOS,
                                         on a server made before EHOS 0.15.0. k3s restarts,
                                         and the console and its applications stop for a few
                                         minutes. Without this flag, ehosctl refuses such a
                                         server. Needs EHOS_STATE_PASSPHRASE.

             OPTIONS:

                 --installation            The installation of the server. By default
                                           EHOSCTL_INSTALLATION, else the current
                                           installation, else trial.
                 --version                 The release of EHOS to install. By default the
                                           newest release.
                 --host                    The host of the console. By default the host that
                                           EHOS serves now, or ehos.<address>.sslip.io on a
                                           first install, from the address of the tunnel.
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

             Plane: platform. This command acts with an account that EHOS does not issue: an account of a cloud provider, an SSH key or a kubeconfig.

             """
    end

    test "refuses an installation whose version nothing recorded, naming upgrade", %{opts: opts} do
      runs(%{running: :unknown})

      assert ehosctl(~w(install), opts) ==
               {2, "",
                "ehosctl: trial runs an EHOS whose version ehosctl cannot read from the " <>
                  "cluster, as `mix ehos.install` leaves it. Run `ehosctl upgrade " <>
                  "--installation trial` to move it to a release. ehosctl changed " <>
                  "nothing.\n"}

      refute_received {:server, _server}
    end

    test "refuses a release that names no image and chart by digest", %{
      github: github,
      opts: opts
    } do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [
        release("0.6.0", %{"image" => "ghcr.io/empoweredhouse/ehos:latest"}),
        release("0.5.0", %{
          "chart" => "oci://elsewhere.example/ehos@sha256:" <> String.duplicate("c", 64)
        })
      ])

      for {argv, tag} <- [{~w(install), "v0.6.0"}, {~w(install --version 0.5.0), "v0.5.0"}] do
        assert ehosctl(argv, opts) == {1, "", no_digests(tag)}
      end

      refute_received {:server, _server}
    end

    test "says what stops it before it asks GitHub, as an unopened tunnel", %{
      github: github,
      opts: opts
    } do
      FakeHTTP.down(github)

      Process.put(
        {Platform, :installed},
        {:error, "…/kubeconfig is missing. Open the tunnel first: `ehosctl server tunnel`"}
      )

      assert ehosctl(~w(install), opts) ==
               {1, "",
                "ehosctl: …/kubeconfig is missing. Open the tunnel first: `ehosctl server tunnel`\n"}
    end

    test "says when EHOS has no release, or one with no release.json", %{
      github: github,
      opts: opts
    } do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [{"v0.4.0", %{"assets" => %{}}}])
      assert ehosctl(~w(install), opts) == {1, "", no_digests("v0.4.0")}

      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [])
      assert ehosctl(~w(install), opts) == {1, "", "ehosctl: EHOS has no release yet.\n"}
    end

    test "prints a failing tool's output with what a terminal would act on escaped", %{
      opts: opts
    } do
      # A revision's description is the cluster's text, and helm prints it (ehos-tools#165).
      Process.put(
        {Platform, :installed},
        {:error, "`helm` failed with exit status 1:\nError: \e]52;c;cGF3bmVk\a\e[2Jrevision 3"}
      )

      assert ehosctl(~w(install), opts) ==
               {1, "",
                "ehosctl: `helm` failed with exit status 1:\n" <>
                  ~S("Error: \u{1B}]52;c;cGF3bmVk\u{7}\u{1B}[2Jrevision 3") <> "\n"}
    end

    # A server made before Stage 13 is under `trial`, while the current installation is named after
    # its host (ehos-tools#194).
    test "refuses an installation no server is known under, naming those that are, before " <>
           "anything runs",
         %{opts: opts} do
      :ok =
        Config.write(
          %Config{
            current: "ehos-92-5-148-138",
            installations: %{
              "ehos-92-5-148-138" => %{"url" => "https://ehos.192-0-2-7.sslip.io"}
            }
          },
          opts[:config_dir]
        )

      assert ehosctl(~w(install), opts) ==
               {2, "",
                "ehosctl: This computer has no server for the installation ehos-92-5-148-138 " <>
                  "(the current installation). It has servers for the installations acme, " <>
                  "trial. Run the command again with --installation and one of them.\n"}

      refute_received {:installed, _opts}
    end
  end

  describe "settled/3" do
    test "names the kubeconfig in ~/.ehos when no home is given" do
      stub_home("/home/someone")
      last = %{revision: 4, status: "pending-upgrade", description: "Preparing upgrade"}

      helm =
        "helm --kubeconfig /home/someone/.ehos/acme/kubeconfig --kube-context ehos-acme -n ehos-system"

      assert Ehosctl.Install.settled(%{last: last, running: :none}, "acme", []) ==
               {:error, :failed,
                pending(
                  "acme",
                  "revision 4 of Helm, is pending-upgrade (Preparing upgrade)",
                  helm
                ) <>
                  "Run `#{helm} uninstall ehos` to remove it, because nothing ran before it. Then " <>
                  "run this command again. ehosctl changed nothing."}
    end

    test "quotes the kubeconfig in what it suggests when the home holds a space" do
      stub_home("/home/Jane Doe")
      last = %{revision: 4, status: "pending-upgrade", description: "Preparing upgrade"}

      helm =
        "helm --kubeconfig '/home/Jane Doe/.ehos/acme/kubeconfig' --kube-context ehos-acme " <>
          "-n ehos-system"

      assert Ehosctl.Install.settled(%{last: last, running: :none}, "acme", []) ==
               {:error, :failed,
                pending(
                  "acme",
                  "revision 4 of Helm, is pending-upgrade (Preparing upgrade)",
                  helm
                ) <>
                  "Run `#{helm} uninstall ehos` to remove it, because nothing ran before it. Then " <>
                  "run this command again. ehosctl changed nothing."}
    end
  end

  # eh-os D-36, ehos-tools#298: the SMTP server EHOS sends mail through, so invitations arrive by
  # email.
  describe "install's SMTP server" do
    test "is given to the platform with the password from SMTP_PASSWORD alone", %{opts: opts} do
      stub_env(Map.put(@env, "SMTP_PASSWORD", "pw"))
      {0, _stdout, ""} = ehosctl(["install" | @smtp], opts)
      assert_server(opts, %{mail: @mail, smtp_password: "pw"})

      assert ehosctl(
               ~w(install --smtp-host mail.example.com --smtp-port 465 --mail-from a@example.com),
               opts
             ) == {0, installed("trial"), relay_warning("mail.example.com:465")}

      assert_server(opts, %{
        mail: %{
          "from" => "a@example.com",
          "smtp" => %{"host" => "mail.example.com", "port" => 465}
        },
        smtp_password: "pw"
      })
    end

    test "sends none when nothing names one", %{opts: opts} do
      {0, _stdout, ""} = ehosctl(~w(install), opts)
      assert_server(opts, %{mail: nil, smtp_password: nil})
    end

    test "keeps the one EHOS runs with, given options over it, until --no-mail", %{opts: opts} do
      runs(%{running: @running, mail: @mail})

      {0, _stdout, ""} = ehosctl(~w(install), opts)
      assert_server(opts, %{mail: @mail})

      assert ehosctl(["install", "--smtp-port", "465", "--smtp-username", ""], opts) ==
               {0, installed("trial"), relay_warning("smtp.example.com:465")}

      assert_server(opts, %{
        mail: %{
          "from" => "ehos@example.com",
          "smtp" => %{"host" => "smtp.example.com", "port" => 465}
        }
      })

      {0, _stdout, ""} = ehosctl(~w(install --no-mail), opts)
      assert_server(opts, %{mail: nil})
    end

    test "adds a user to the one EHOS runs with, and refuses a given value that does not fit",
         %{opts: opts} do
      running = %{"from" => "ehos@example.com", "smtp" => %{"host" => "h", "port" => 587}}
      runs(%{running: @running, mail: running})
      stub_env(Map.put(@env, "SMTP_PASSWORD", "pw"))
      {0, _stdout, ""} = ehosctl(~w(install --smtp-username ehos), opts)

      assert_server(opts, %{
        mail: put_in(running, ["smtp", "username"], "ehos"),
        smtp_password: "pw"
      })

      runs(%{running: @running, mail: running})
      stub_env(@env)

      assert ehosctl(~w(install --mail-from bad), opts) ==
               {2, "",
                ~s(ehosctl: --mail-from must be an email address, and "bad" is not. Give an email address.\n)}
    end

    # eh-os D-141: a relay that admits the server by its address admits every application on it.
    test "warns where it sends through a server with no user, and installs all the same",
         %{opts: opts} do
      for argv <- [
            ~w(--smtp-host smtp.example.com --mail-from ehos@example.com),
            ~w(--smtp-host smtp.example.com --smtp-username) ++ [""] ++ ~w(--mail-from a@b.co)
          ] do
        assert ehosctl(["install" | argv], opts) ==
                 {0, installed("trial"), relay_warning("smtp.example.com:587")}

        assert_received {:server, _server}
      end

      # Kept from the EHOS that runs, it is said again.
      runs(%{
        running: @running,
        mail: %{
          "from" => "ehos@example.com",
          "smtp" => %{"host" => "h.example.com", "port" => 465}
        }
      })

      assert ehosctl(~w(install), opts) ==
               {0, installed("trial"), relay_warning("h.example.com:465")}

      # A user, or no mail, says nothing.
      stub_env(Map.put(@env, "SMTP_PASSWORD", "pw"))
      {0, _stdout, ""} = ehosctl(["install" | @smtp], opts)
      {0, _stdout, ""} = ehosctl(~w(install --no-mail), opts)
    end

    test "sends no password left in the shell where it sends no mail", %{opts: opts} do
      runs(%{running: @running, mail: @mail})
      stub_env(Map.put(@env, "SMTP_PASSWORD", "leftover"))
      {0, _stdout, ""} = ehosctl(~w(install --no-mail), opts)
      assert_server(opts, %{mail: nil, smtp_password: nil})
    end

    test "is refused before anything changes when it is not whole or not what the chart takes",
         %{opts: opts} do
      for {argv, refused} <- [
            {~w(--smtp-host smtp.example.com),
             "--smtp-host needs --mail-from, the address that EHOS sends mail from."},
            {~w(--mail-from a@example.com),
             "--mail-from needs --smtp-host, the SMTP server that EHOS sends mail through."},
            {~w(--smtp-port 2525 --smtp-username u),
             "--smtp-port, --smtp-username need --smtp-host, the SMTP server that EHOS sends mail through."},
            {@smtp ++ ~w(--smtp-port 70000),
             ~s(--smtp-port must be a port from 1 to 65535, and "70000" is not. Give a port in that range.)},
            {~w(--smtp-host smtp.example.com --mail-from nobody),
             ~s(--mail-from must be an email address, and "nobody" is not. Give an email address.)},
            {~w(--smtp-host bad_host! --mail-from a@example.com),
             ~s(--smtp-host must be a DNS name, and "bad_host!" is not. Give a DNS name.)},
            {["--smtp-host", "h.example.com", "--mail-from", "a@example.com\r\nBcc: x@y.com"],
             ~S(--mail-from must be an email address, and "a@example.com\r\nBcc: x@y.com" is not. Give an email address.)},
            {@smtp ++ ~w(--no-mail),
             "--no-mail stops the mail of EHOS, so it takes no SMTP option. Leave out " <>
               "--mail-from, --smtp-host, --smtp-username."}
          ] do
        assert ehosctl(["install" | argv], opts) == {2, "", "ehosctl: #{refused}\n"}
        refute_received {:server, _server}
      end
    end

    # The password the cluster holds was given for one server and user: EHOS would otherwise send
    # it to another.
    test "asks for SMTP_PASSWORD where the host or the user is not the one it was given for",
         %{opts: opts} do
      for {argv, user, host} <- [
            {~w(--smtp-host other.example.com), "ehos", "other.example.com"},
            {~w(--smtp-username bob), "bob", "smtp.example.com"}
          ] do
        runs(%{running: @running, mail: @mail})
        stub_env(@env)

        assert ehosctl(["install" | argv], opts) ==
                 {2, "",
                  "ehosctl: The cluster holds no password for #{user} at #{host}: its password, if " <>
                    "any, is for ehos at smtp.example.com. Set SMTP_PASSWORD to the password " <>
                    "of #{user}, and run the command again. ehosctl changed nothing.\n"}

        refute_received {:server, _server}

        runs(%{running: @running, mail: @mail})
        stub_env(Map.put(@env, "SMTP_PASSWORD", "pw"))
        {0, _stdout, ""} = ehosctl(["install" | argv], opts)

        assert_server(opts, %{
          mail: %{
            "from" => "ehos@example.com",
            "smtp" => %{"host" => host, "port" => 587, "username" => user}
          },
          smtp_password: "pw"
        })
      end

      runs(%{running: @running})
      stub_env(@env)

      assert ehosctl(["install" | @smtp], opts) ==
               {2, "",
                "ehosctl: The cluster holds no password for ehos at smtp.example.com: its " <>
                  "password, if any, is for no user EHOS runs with. Set SMTP_PASSWORD to the " <>
                  "password of ehos, and run the command again. ehosctl changed nothing.\n"}

      # A DNS name is the same whatever its case.
      runs(%{running: @running, mail: @mail})
      {0, _stdout, ""} = ehosctl(~w(install --smtp-host SMTP.Example.com --smtp-port 465), opts)

      assert_server(opts, %{
        mail: %{
          "from" => "ehos@example.com",
          "smtp" => %{"host" => "SMTP.Example.com", "port" => 465, "username" => "ehos"}
        }
      })
    end

    # Settings someone set with Helm by hand: never turned off without a word.
    test "refuses to keep settings it did not write, unless replaced or stopped", %{opts: opts} do
      runs(%{running: @running, mail: :unreadable})
      assert ehosctl(~w(install), opts) == {2, "", @unwritten}
      refute_received {:server, _server}

      assert ehosctl(~w(install --smtp-port 465), opts) == {2, "", @unwritten}

      assert ehosctl(~w(install --smtp-host h.example.com --mail-from a@example.com), opts) ==
               {0, installed("trial"), relay_warning("h.example.com:587")}

      assert_server(opts, %{
        mail: %{"from" => "a@example.com", "smtp" => %{"host" => "h.example.com", "port" => 587}}
      })

      {0, _stdout, ""} = ehosctl(~w(install --no-mail), opts)
      assert_server(opts, %{mail: nil})
    end

    test "refuses a password with no server to give it to, unless --no-mail", %{opts: opts} do
      stub_env(Map.put(@env, "SMTP_PASSWORD", "leftover"))

      assert ehosctl(~w(install), opts) ==
               {2, "",
                "ehosctl: SMTP_PASSWORD is set, but EHOS has no SMTP server to use it " <>
                  "with. Give --smtp-host and --mail-from, unset SMTP_PASSWORD, or give " <>
                  "--no-mail. ehosctl changed nothing.\n"}

      refute_received {:server, _server}
    end
  end

  # eh-os D-113: how long a sign-in to an application lasts, given to the chart of an EHOS that
  # takes it.
  describe "install's sign-in limits" do
    setup %{github: github} do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [release("0.10.0"), release("0.6.0")])
      :ok
    end

    test "are given to the platform, and those EHOS runs with are kept", %{opts: opts} do
      {0, _stdout, ""} = ehosctl(~w(install --sign-in-absolute 30d --sign-in-idle 14d), opts)

      assert_server(opts, %{
        installed: @running_0_10,
        sign_in: %{"absolute" => "30d", "idle" => "14d"}
      })

      {0, _stdout, ""} = ehosctl(~w(install), opts)
      assert_server(opts, %{installed: @running_0_10, sign_in: nil})

      runs(%{running: @running_0_10, sign_in: %{"absolute" => "30d"}})

      {0, _stdout, ""} = ehosctl(~w(install --sign-in-idle 7d), opts)

      assert_server(opts, %{
        installed: @running_0_10,
        sign_in: %{"absolute" => "30d", "idle" => "7d"}
      })
    end

    test "take the bounds the chart takes", %{opts: opts} do
      for {argv, sign_in} <- [
            {~w(--sign-in-absolute 366d), %{"absolute" => "366d"}},
            {~w(--sign-in-absolute 2d --sign-in-idle 48h), %{"absolute" => "2d", "idle" => "48h"}}
          ] do
        {0, _stdout, ""} = ehosctl(["install" | argv], opts)
        assert_server(opts, %{installed: @running_0_10, sign_in: sign_in})
      end
    end

    test "are refused as the chart would refuse them, before anything changes", %{opts: opts} do
      for {argv, refused} <- [
            {~w(--sign-in-absolute 30m),
             ~s(--sign-in-absolute must be whole hours or days, and "30m" is not. ) <>
               "Give a value such as 12h or 30d."},
            {~w(--sign-in-idle 0d),
             ~s(--sign-in-idle must be whole hours or days, and "0d" is not. ) <>
               "Give a value such as 12h or 30d."},
            {~w(--sign-in-absolute 367d),
             "--sign-in-absolute (367d) must be at most 366d. Give --sign-in-absolute of 366d or less."},
            {~w(--sign-in-idle 13h),
             "--sign-in-idle (13h) must be at most the default absolute limit (12h). Give a shorter --sign-in-idle or a longer --sign-in-absolute."}
          ] do
        assert ehosctl(["install" | argv], opts) == {2, "", "ehosctl: #{refused}\n"}
        refute_received {:server, _server}
      end
    end

    test "name the value EHOS runs with when it is the one that does not fit", %{opts: opts} do
      runs(%{running: @running_0_10, sign_in: %{"absolute" => "30d", "idle" => "14d"}})

      assert ehosctl(~w(install --sign-in-absolute 7d), opts) ==
               {2, "",
                "ehosctl: The idle limit that EHOS uses now (14d) must be at most " <>
                  "--sign-in-absolute (7d). Give a shorter --sign-in-idle or a longer --sign-in-absolute.\n"}
    end

    test "are refused for an EHOS before 0.10.0, which has none to set", %{opts: opts} do
      assert ehosctl(~w(install --version 0.6.0 --sign-in-absolute 30d), opts) ==
               {2, "",
                "ehosctl: EHOS 0.6.0 has no sign-in limits to set: before 0.10.0, they " <>
                  "are always 12h and 1h. Leave out --sign-in-absolute and --sign-in-idle, " <>
                  "or install 0.10.0 or later.\n"}

      refute_received {:server, _server}
    end
  end

  # eh-os D-105, ehos-tools#296: whether a promotion needs a second person, kept from the running
  # EHOS, so a reinstall does not turn four eyes back on.
  describe "install's four eyes" do
    setup %{github: github} do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [release("0.10.0"), release("0.8.0")])
      :ok
    end

    test "are given to the platform, and what EHOS runs with is kept", %{opts: opts} do
      {0, _stdout, ""} = ehosctl(~w(install), opts)
      assert_server(opts, %{installed: @running_0_10, four_eyes: nil})

      {0, _stdout, ""} = ehosctl(~w(install --no-four-eyes), opts)
      assert_server(opts, %{installed: @running_0_10, four_eyes: false})

      runs(%{running: @running_0_10, four_eyes: false})
      {0, _stdout, ""} = ehosctl(~w(install), opts)
      assert_server(opts, %{installed: @running_0_10, four_eyes: false})

      {0, _stdout, ""} = ehosctl(~w(install --four-eyes), opts)
      assert_server(opts, %{installed: @running_0_10, four_eyes: true})
    end

    test "are refused both ways at once", %{opts: opts} do
      assert ehosctl(~w(install --four-eyes --no-four-eyes), opts) ==
               {2, "", "ehosctl: Give --four-eyes or --no-four-eyes, not both.\n"}

      refute_received {:server, _server}
    end

    test "are refused for an EHOS before 0.9.0, which has no setting for them", %{opts: opts} do
      assert ehosctl(~w(install --version 0.8.0 --no-four-eyes), opts) ==
               {2, "",
                "ehosctl: EHOS 0.8.0 has no setting for four eyes, because promotions " <>
                  "start in 0.9.0. Leave out --no-four-eyes, or install 0.9.0 or later.\n"}

      refute_received {:server, _server}
    end
  end

  # eh-os D-124: a server on Oracle that moved to a reserved address has a new one, which the
  # console's host of sslip.io, kept from what runs, would not name.
  describe "install on a server whose address changed" do
    setup %{opts: opts} do
      runs(%{running: @running, host: "ehos.192-0-2-1.sslip.io"})
      %{tunnel: Path.join([opts[:home], "trial", "tunnel.json"])}
    end

    test "keeps the host where the address is the same, unknown, or the host no sslip.io name",
         %{opts: opts, tunnel: tunnel} do
      File.write!(tunnel, ~s({"address": "192.0.2.1", "port": 16443}))
      {0, _stdout, ""} = ehosctl(~w(install --version 0.6.0), opts)
      assert_server(opts, %{host: "ehos.192-0-2-1.sslip.io"})

      File.rm!(tunnel)
      {0, _stdout, ""} = ehosctl(~w(install --version 0.6.0), opts)
      assert_server(opts, %{host: "ehos.192-0-2-1.sslip.io"})
    end

    test "is refused a kept host that names the old address, with the --host to give",
         %{opts: opts, tunnel: tunnel} do
      File.write!(tunnel, ~s({"address": "198.51.100.9", "port": 16443}))

      assert ehosctl(~w(install --version 0.6.0), opts) ==
               {2, "",
                "ehosctl: EHOS on trial serves its console at ehos.192-0-2-1.sslip.io, " <>
                  "which names 192.0.2.1, but the server is at 198.51.100.9 now. To move " <>
                  "the console and the address of each application, give --host " <>
                  "ehos.198-51-100-9.sslip.io. ehosctl changed nothing.\n"}

      refute_received {:server, _server}

      {0, _stdout, ""} =
        ehosctl(~w(install --version 0.6.0 --host ehos.198-51-100-9.sslip.io), opts)

      assert_server(opts, %{host: "ehos.198-51-100-9.sslip.io"})
    end
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

  # What runs on the server, as the platform reads it: nothing, unless `fields` say otherwise.
  defp runs(fields),
    do:
      Process.put(
        {Platform, :installed},
        {:ok,
         Map.merge(
           %{
             running: :none,
             digest: nil,
             host: nil,
             sign_in: nil,
             four_eyes: nil,
             mail: nil,
             last: nil
           },
           fields
         )}
      )

  # What `install` says when it installed on `name`, and kept the installation for login.
  defp installed(name),
    do:
      @running_at <>
        "Sign in with `ehosctl login --installation #{name}`. It trusts the CA of the installation.\n"

  # The relay warning of eh-os D-141 for a server at `address`: one line, nothing else said.
  defp relay_warning(address),
    do:
      "==> Warning: EHOS sends mail through #{address} with no SMTP user. If the relay admits the server by its address, it admits each application on the server. An application that names #{address |> String.split(":") |> hd()} under needs.egress can then send as anyone in the domain of the company, outside its mail agreement. If applications of others run here, give EHOS a user of the relay (--smtp-username, with SMTP_PASSWORD). Then make the relay require that user, not the address of the server.\n"

  # What the refusal to change EHOS under a Helm operation on `name` says up to its way out.
  defp pending(name, revision, helm),
    do:
      "The last change to EHOS on #{name}, #{revision}. An install or upgrade is running, " <>
        "or one stopped before it ended. Wait for it to end. If it stopped, " <>
        "`#{helm} history ehos` shows the revisions. "

  defp no_digests(tag),
    do:
      "ehosctl: #{tag} does not name an image and a chart of EHOS by digest, so ehosctl cannot install it. Give a later release.\n"

  # What the platform is told of the installation `name`, to read what runs there and to install.
  defp base(opts, name),
    do: [
      name: name,
      home: opts[:home],
      runner: Ehosctl.PlatformRunner,
      server_command: "ehosctl server",
      name_option: "--installation",
      name_in_commands: true
    ]

  # The install the platform was asked for: the newest release on `trial`, as nothing names
  # otherwise, with `fields` over it. Its progress is a function, said apart.
  defp assert_server(opts, fields \\ %{}) do
    assert_received {:server, server}

    expected =
      opts
      |> base(Map.get(fields, :name, "trial"))
      |> Map.new()
      |> Map.merge(%{
        source: %EhosPlatform.Source{chart: {:oci, @chart}, modules: nil},
        digest: "sha256:" <> String.duplicate("b", 64),
        installed: @running,
        host: nil,
        sign_in: nil,
        four_eyes: nil,
        mail: nil,
        smtp_password: nil,
        token: "ghp_token",
        username: nil,
        passphrase: "a passphrase of 16+",
        switch_traefik: false,
        ssh_key: nil
      })
      |> Map.merge(fields)

    assert given(server) == expected
  end

  # The options the platform was given, but the function it reports progress through.
  defp given(server) do
    {progress, given} = Keyword.pop!(server, :progress)
    assert is_function(progress, 1)
    Map.new(given)
  end
end
