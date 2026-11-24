defmodule Ehosctl.ServerTest do
  # Not async: capture_io(:stderr) captures stderr for every process, so tests that run beside
  # each other would read each other's errors.
  use Ehosctl.Case, async: false

  alias Ehosctl.Config
  alias Ehosctl.FakeGitHub
  alias Ehosctl.FakeHTTP

  @moduletag :tmp_dir

  # In place of `EhosPlatform.Server`: says what it was asked, with which options, and answers.
  defmodule Platform do
    @moduledoc false

    # A test makes one fail with `answer_platform/2`.
    for fun <- [:up, :down, :status, :tunnel, :close_tunnel] do
      def unquote(fun)(opts) do
        send(self(), {:platform, unquote(fun), opts})

        case Process.get(
               {__MODULE__, unquote(fun)},
               {:ok, %EhosPlatform.Report{outcome: "#{unquote(fun)} done."}}
             ) do
          answer when is_function(answer, 1) -> answer.(opts)
          answer -> answer
        end
      end
    end

    defdelegate made?(opts), to: EhosPlatform.Server
  end

  # In place of `EhosPlatform.Server.Administrators`: says what it was asked, and answers.
  defmodule Administrators do
    @moduledoc false

    def add(name, public_key, opts), do: answer({:add, name, public_key}, opts)
    def remove(name, opts), do: answer({:remove, name}, opts)
    def list(opts), do: answer(:list, opts)

    defp answer(call, opts) do
      send(self(), {:administrators, call, opts |> Map.new() |> Map.delete(:progress)})
      Process.get({__MODULE__, :answer}, {:ok, %EhosPlatform.Report{outcome: "Done."}})
    end
  end

  # In place of `EhosPlatform.Install`: says what it was asked to invite, and answers.
  defmodule Invite do
    @moduledoc false

    def invite(opts) do
      send(self(), {:invite, opts})
      Process.get({__MODULE__, :invite})
    end
  end

  # In place of the platform's runner, for the invitation run through `EhosPlatform.Install`:
  # says what kubectl was asked, and answers as EHOS's release command printed.
  defmodule Kubectl do
    @moduledoc false

    def run_bounded("kubectl", args, _timeout) do
      send(self(), {:kubectl, args})
      Process.get({__MODULE__, :answer})
    end
  end

  @chart "oci://ghcr.io/empoweredhouse/charts/ehos@sha256:" <> String.duplicate("a", 64)
  @passphrase String.duplicate("p", 16)

  @name_rule "The installation's name is 2 to 16 lowercase letters, digits and hyphens"

  @modules_gone "ehosctl: The release of EHOS 0.5.0 on GitHub no longer names the " <>
                  "modules that made this server, and their archive is not on this " <>
                  "machine. ehosctl changed nothing.\n"

  @yes_refused "ehosctl: ehosctl removed nothing. --yes needs --installation on the " <>
                 "command line, with the installation whose server it removes. " <>
                 "EHOSCTL_INSTALLATION and the current installation (acme here) do not " <>
                 "count.\n"

  @link "https://ehos.192-0-2-7.sslip.io/people/log-in/" <> String.duplicate("aB3_-", 9)
  @invited_line "Invited ada@example.com. This link signs them in once, within 15 minutes:"

  setup %{tmp_dir: dir} do
    github = FakeGitHub.start()

    opts =
      [
        server: Platform,
        home: Path.join(dir, "ehos"),
        config_dir: Path.join(dir, "config"),
        passphrase: @passphrase
      ]

    %{github: github, opts: opts, home: Path.join(dir, "ehos")}
  end

  describe "installation/2" do
    test "is --installation, else EHOSCTL_INSTALLATION, else the current one, else trial", %{
      opts: opts,
      home: home
    } do
      for name <- ~w(trial acme staging check), do: made(home, name)
      assert Ehosctl.Server.installation(nil, opts) == {:ok, "trial"}

      :ok =
        Config.write(
          %Config{current: "acme", installations: %{"acme" => %{"url" => "https://ehos.acme"}}},
          opts[:config_dir]
        )

      assert Ehosctl.Server.installation(nil, opts) == {:ok, "acme"}

      stub_env(%{"EHOSCTL_INSTALLATION" => "staging"})
      assert Ehosctl.Server.installation(nil, opts) == {:ok, "staging"}
      assert Ehosctl.Server.installation("check", opts) == {:ok, "check"}
    end

    test "is looked for in ~/.ehos when no home is given", %{opts: opts, tmp_dir: dir} do
      stub_home(dir)
      made(Path.join(dir, ".ehos"), "acme")

      assert Ehosctl.Server.installation("acme", Keyword.delete(opts, :home)) == {:ok, "acme"}
    end
  end

  describe "server up" do
    test "makes the server from the newest release's modules, checked, and keeps them", %{
      github: github,
      opts: opts,
      home: home,
      tmp_dir: dir
    } do
      serve_releases(github, [release("0.6.0", modules(dir)), release("0.5.0", modules(dir))])

      argv =
        ~w(server up --provider oci --ssh-from 192.0.2.1 --ssh-from 198.51.100.0/24 --ocpus 1 --replace --public-certificates)

      assert ehosctl(argv, opts) == {0, "✓ up done.\n", ""}

      # Planned from where it was checked, and kept once `up` succeeded.
      assert platform_calls() == [
               up:
                 platform_opts(home, "trial",
                   source: source(home, "trial", "release.next"),
                   provider: "oci",
                   ssh_from: ["192.0.2.1", "198.51.100.0/24"],
                   ocpus: 1,
                   replace: true,
                   public_certificates: true
                 )
             ]

      kept = Path.join([home, "trial", "release", "modules", "deploy/tofu/oci/main.tf"])
      assert File.read!(kept) == "# oci\n"
      assert kept(home) == "0.6.0"
    end

    test "makes the first server under the current installation's name", %{
      opts: opts,
      home: home,
      github: github,
      tmp_dir: dir
    } do
      serve_releases(github, [release("0.6.0", modules(dir))])
      current!(opts, "acme")

      assert ehosctl(~w(server up --provider oci), opts) == {0, "✓ up done.\n", ""}

      assert platform_calls() == [
               up:
                 platform_opts(home, "acme",
                   source: source(home, "acme", "release.next"),
                   provider: "oci"
                 )
             ]
    end

    test "takes the release --version names", %{
      github: github,
      opts: opts,
      home: home,
      tmp_dir: dir
    } do
      serve_releases(github, [release("0.6.0", modules(dir)), release("0.5.0", modules(dir))])

      assert ehosctl(~w(server up --provider oci --version 0.5.0), opts) ==
               {0, "✓ up done.\n", ""}

      assert kept(home) == "0.5.0"

      assert ehosctl(~w(server up --provider oci --version 0.4.0), opts) ==
               {2, "", "ehosctl: EHOS has no release 0.4.0.\n"}
    end

    test "keeps a release it downloaded only once up has succeeded", %{
      github: github,
      opts: opts,
      home: home,
      tmp_dir: dir
    } do
      serve_releases(github, [release("0.6.0", modules(dir)), release("0.5.0", modules(dir))])

      {0, _stdout, ""} = ehosctl(~w(server up --provider oci --version 0.5.0), opts)
      _up = platform_calls()

      answer_platform(:up, {:error, "the plan would replace the server"})

      assert ehosctl(~w(server up --provider oci --version 0.6.0), opts) ==
               {1, "", "ehosctl: the plan would replace the server\n"}

      assert platform_calls() == [
               up:
                 platform_opts(home, "trial",
                   source: source(home, "trial", "release.next"),
                   provider: "oci"
                 )
             ]

      assert kept(home) == "0.5.0"
      refute File.exists?(Path.join([home, "trial", "release.next"]))

      answer_platform(:up, nil)

      assert ehosctl(~w(server up --provider oci --version 0.6.0), opts) ==
               {0, "✓ up done.\n", ""}

      assert kept(home) == "0.6.0"
    end

    test "keeps a release whose apply was reached, though what came after it failed", %{
      github: github,
      opts: opts,
      home: home,
      tmp_dir: dir
    } do
      serve_releases(github, [release("0.6.0", modules(dir)), release("0.5.0", modules(dir))])

      {0, _stdout, ""} = ehosctl(~w(server up --provider oci --version 0.5.0), opts)

      answer_platform(:up, fn up ->
        File.write!(Path.join(EhosPlatform.Server.dir(up), "terraform.tfstate"), "applied")
        {:error, "The server's first boot did not finish cleanly"}
      end)

      assert ehosctl(~w(server up --provider oci --version 0.6.0), opts) ==
               {1, "", "ehosctl: The server's first boot did not finish cleanly\n"}

      assert kept(home) == "0.6.0"
    end

    test "without --version, keeps to the release kept, though a newer one is out", %{
      github: github,
      opts: opts,
      home: home,
      tmp_dir: dir
    } do
      serve_releases(github, [release("0.6.0", modules(dir)), release("0.5.0", modules(dir))])

      {0, _stdout, ""} = ehosctl(~w(server up --provider oci --version 0.5.0), opts)
      assert ehosctl(~w(server up --provider oci), opts) == {0, "✓ up done.\n", ""}
      assert kept(home) == "0.5.0"
    end

    test "refuses a name the OpenTofu module would refuse, before anything runs", %{
      opts: opts
    } do
      assert ehosctl(["server", "up", "--installation", "a-name-longer-than-sixteen"], opts) ==
               {2, "",
                "ehosctl: a-name-longer-than-sixteen cannot be the name of a server: " <>
                  @name_rule <> "\n"}

      assert platform_calls() == []
    end

    test "makes no new server under the current installation's name while another has one",
         %{opts: opts, home: home, github: github, tmp_dir: dir} do
      serve_releases(github, [release("0.6.0", modules(dir))])
      made(home, "trial")
      current!(opts, "acme")

      assert ehosctl(~w(server up --provider oci), opts) ==
               {2, "",
                "ehosctl: This computer has no server for the installation acme (the current " <>
                  "installation). It has a server for the installation trial. `up` makes a new " <>
                  "server only for a name that you give. Run it again with --installation " <>
                  "trial to change that server, or with --installation acme --provider " <>
                  "PROVIDER (aws, gcp, oci, ovh) to make a new server.\n"}

      current!(opts, "ehos-92-5-148-138")

      assert ehosctl(~w(server up --provider oci), opts) ==
               {2, "",
                "ehosctl: This computer has no server for the installation ehos-92-5-148-138 " <>
                  "(the current installation). It has a server for the installation trial. " <>
                  "`up` makes a new server only for a name that you give. Run it again with " <>
                  "--installation trial to change that server, or with a new name to make a " <>
                  "new server (" <> @name_rule <> ").\n"}

      assert platform_calls() == []

      assert ehosctl(~w(server up --provider oci --installation acme), opts) ==
               {0, "✓ up done.\n", ""}

      assert platform_calls() == [
               up:
                 platform_opts(home, "acme",
                   source: source(home, "acme", "release.next"),
                   provider: "oci"
                 )
             ]
    end

    test "makes no new trial server, when no installation is named or current, while " <>
           "another has one",
         %{opts: opts, home: home, github: github, tmp_dir: dir} do
      serve_releases(github, [release("0.6.0", modules(dir))])
      made(home, "acme")

      assert ehosctl(~w(server up --provider oci), opts) ==
               {2, "",
                "ehosctl: This computer has no server for the installation trial (no " <>
                  "installation is named or current). It has a server for the installation " <>
                  "acme. `up` makes a new server only for a name that you give. Run it again " <>
                  "with --installation acme to change that server, or with --installation " <>
                  "trial --provider PROVIDER (aws, gcp, oci, ovh) to make a new server.\n"}

      assert platform_calls() == []

      assert ehosctl(~w(server up --provider oci --installation trial), opts) ==
               {0, "✓ up done.\n", ""}

      assert platform_calls() == [
               up:
                 platform_opts(home, "trial",
                   source: source(home, "trial", "release.next"),
                   provider: "oci"
                 )
             ]
    end

    # eh-os D-126: no cloud is chosen for the operator, and nothing is downloaded for an `up` that
    # will be refused for it.
    test "downloads no release for a server not made yet when no --provider names its cloud", %{
      github: github,
      opts: opts,
      home: home,
      tmp_dir: dir
    } do
      serve_releases(github, [release("0.6.0", modules(dir))])

      assert ehosctl(~w(server up), opts) ==
               {2, "",
                "ehosctl: Name the cloud to make ehos-trial in with --provider aws, gcp, oci, ovh; " <>
                  "EHOS does not choose one for you. The server stays there: every later command " <>
                  "reads it from the installation\n"}

      assert platform_calls() == []
      refute File.exists?(Path.join([home, "trial", "release.next"]))
      assert kept(home) == nil

      assert ehosctl(~w(server up --provider aws), opts) == {0, "✓ up done.\n", ""}

      assert platform_calls() == [
               up:
                 platform_opts(home, "trial",
                   source: source(home, "trial", "release.next"),
                   provider: "aws"
                 )
             ]
    end

    # ehos-tools#345: a damaged record is a failure, exit 1, not a usage error.
    test "fails, rather than refusing the command line, when the installation's record is damaged",
         %{opts: opts, home: home} do
      made(home, "trial")
      File.write!(Path.join([home, "trial", "installation.json"]), "{")

      assert ehosctl(~w(server up), opts) ==
               {1, "",
                "ehosctl: #{home}/trial/installation.json cannot be read as an installation's " <>
                  "place; restore it\n"}

      assert platform_calls() == []
    end

    test "refuses a modules' archive whose SHA-256 is not the one release.json names, and keeps " <>
           "the release it had",
         %{github: github, opts: opts, home: home, tmp_dir: dir} do
      {archive, sha256} = modules(dir)

      serve_releases(github, [
        release("0.6.0", {archive, String.duplicate("0", 64)}),
        release("0.5.0", modules(dir))
      ])

      assert ehosctl(~w(server up --provider oci --version 0.5.0), opts) ==
               {0, "✓ up done.\n", ""}

      _up = platform_calls()

      assert ehosctl(~w(server up --provider oci --version 0.6.0), opts) ==
               {1, "",
                "ehosctl: #{home}/trial/release.next/ehos-modules.tar.gz has the SHA-256 " <>
                  "#{sha256}, not #{String.duplicate("0", 64)}, which the release names; nothing " <>
                  "was unpacked\n"}

      assert platform_calls() == []
      assert kept(home) == "0.5.0"
      refute File.exists?(Path.join([home, "trial", "release.next"]))

      # And the kept release still makes the server, with no download.
      FakeHTTP.down(github)
      assert ehosctl(~w(server up --provider oci), opts) == {0, "✓ up done.\n", ""}
    end

    test "refuses to guess which release to plan with when the kept one cannot be read", %{
      github: github,
      opts: opts,
      home: home,
      tmp_dir: dir
    } do
      serve_releases(github, [release("0.6.0", modules(dir)), release("0.5.0", modules(dir))])

      {0, _stdout, ""} = ehosctl(~w(server up --provider oci --version 0.5.0), opts)
      made(home, "trial")
      file = Path.join([home, "trial", "release", "release.json"])
      File.write!(file, File.read!(file) |> String.replace(~s("0.5.0"), ~s("0.5.0\\u001b[2J")))

      for command <- ~w(up status) do
        assert ehosctl(["server", command, "--provider", "oci"], opts) ==
                 {1, "",
                  "ehosctl: #{home}/trial/release/release.json is missing or does not describe " <>
                    "a release. To keep one again, run `ehosctl server up --installation trial " <>
                    "--version VERSION`, with the release of the server as VERSION.\n"}
      end

      assert ehosctl(~w(server up --provider oci --version 0.5.0), opts) ==
               {0, "✓ up done.\n", ""}

      assert kept(home) == "0.5.0"
    end

    test "takes the kept version again only if it still names the same archive", %{
      github: github,
      opts: opts,
      home: home,
      tmp_dir: dir
    } do
      serve_releases(github, [release("0.5.0", modules(dir))])
      {0, _stdout, ""} = ehosctl(~w(server up --provider oci), opts)
      _up = platform_calls()
      File.rm!(Path.join([home, "trial", "release", "ehos-modules.tar.gz"]))
      serve_releases(github, [release("0.5.0", modules(dir, "aws"))])

      assert ehosctl(~w(server up --provider oci), opts) == {1, "", @modules_gone}
      assert platform_calls() == []
    end

    test "refuses a release that names no modules", %{github: github, opts: opts} do
      serve_releases(github, [
        {"v0.4.0",
         %{
           "assets" => %{
             "release.json" => %{
               "schema" => "ehos.release/v1",
               "component" => "ehos",
               "version" => "0.4.0"
             }
           }
         }}
      ])

      assert ehosctl(~w(server up --provider oci), opts) ==
               {1, "",
                "ehosctl: v0.4.0 names no chart and no modules to make a server from. " <>
                  "Give a later release with --version.\n"}
    end
  end

  describe "server admin" do
    setup %{github: github, opts: opts, home: home, tmp_dir: dir} do
      serve_releases(github, [release("0.5.0", modules(dir))])
      {0, _stdout, ""} = ehosctl(~w(server up --provider oci), opts)
      made(home, "trial")
      _up = platform_calls()
      FakeHTTP.down(github)

      %{opts: Keyword.put(opts, :administrators, Administrators)}
    end

    test "adds, removes and lists over the release up kept, with the key given", %{
      opts: opts,
      home: home,
      tmp_dir: dir
    } do
      key = Path.join(dir, "bob.pub")

      assert ehosctl(["server", "admin", "add", "bob", "--public-key", key], opts) ==
               {0, "✓ Done.\n", ""}

      assert ehosctl(~w(server admin remove shared --ssh-key /keys/ada), opts) ==
               {0, "✓ Done.\n", ""}

      assert ehosctl(~w(server admin list), opts) == {0, "✓ Done.\n", ""}

      kept = platform_opts(home, "trial", source: source(home, "trial", "release"))

      assert administrators_calls() == [
               {{:add, "bob", key}, kept},
               {{:remove, "shared"}, Map.put(kept, :ssh_key, "/keys/ada")},
               {:list, kept}
             ]
    end

    test "up names the first administrator and the provisioning key it is given", %{
      opts: opts,
      home: home
    } do
      assert ehosctl(~w(server up --administrator ada --provisioning-key /keys/ada.pub), opts) ==
               {0, "✓ up done.\n", ""}

      assert platform_calls() == [
               up:
                 platform_opts(home, "trial",
                   source: source(home, "trial", "release"),
                   administrator: "ada",
                   provisioning_key: "/keys/ada.pub"
                 )
             ]
    end

    test "fails with what the server said", %{opts: opts} do
      Process.put(
        {Administrators, :answer},
        {:error,
         "ehosctl did not remove ada, because ada is the last installation administrator."}
      )

      assert ehosctl(~w(server admin remove ada), opts) ==
               {1, "",
                "ehosctl: ehosctl did not remove ada, because ada is the last installation " <>
                  "administrator.\n"}
    end

    test "needs a name, and --public-key to add", %{opts: opts} do
      assert {2, "", error} = ehosctl(~w(server admin add bob), opts)
      assert error =~ "--public-key"
      assert administrators_calls() == []
    end
  end

  describe "server status, tunnel and down" do
    test "plan against the release up kept, without asking GitHub", %{
      github: github,
      opts: opts,
      home: home,
      tmp_dir: dir
    } do
      serve_releases(github, [release("0.5.0", modules(dir))])
      {0, _stdout, ""} = ehosctl(~w(server up --provider oci), opts)
      made(home, "trial")
      _up = platform_calls()

      # A newer release is out, and then GitHub no longer answers: neither changes the modules.
      serve_releases(github, [release("0.6.0", modules(dir)), release("0.5.0", modules(dir))])
      FakeHTTP.down(github)

      assert ehosctl(~w(server status), opts) == {0, "✓ status done.\n", ""}
      assert ehosctl(~w(server tunnel --port 16500), opts) == {0, "✓ tunnel done.\n", ""}

      # ehosctl knows no installation trial, so it has nothing to forget.
      assert ehosctl(~w(server down --installation trial --yes), opts) ==
               {0, "✓ down done.\n", ""}

      kept = source(home, "trial", "release")

      assert platform_calls() == [
               status: platform_opts(home, "trial", source: kept),
               tunnel: platform_opts(home, "trial", source: kept, port: 16_500),
               down: platform_opts(home, "trial", source: kept)
             ]

      assert kept(home) == "0.5.0"
    end

    # Run as printed, a command that left the installation out would reach whichever is current
    # by then (ehos-tools#194).
    test "name the installation in every command the platform suggests", %{
      opts: opts,
      home: home,
      github: github,
      tmp_dir: dir
    } do
      serve_releases(github, [release("0.6.0", modules(dir))])
      made(home, "trial")

      assert ehosctl(~w(server status), opts) == {0, "✓ status done.\n", ""}

      assert platform_calls() == [
               status: platform_opts(home, "trial", source: source(home, "trial", "release"))
             ]
    end

    test "download the kept release again when its archive is gone, and only that one", %{
      github: github,
      opts: opts,
      home: home,
      tmp_dir: dir
    } do
      serve_releases(github, [release("0.6.0", modules(dir)), release("0.5.0", modules(dir))])

      {0, _stdout, ""} = ehosctl(~w(server up --provider oci --version 0.5.0), opts)
      made(home, "trial")
      File.rm!(Path.join([home, "trial", "release", "ehos-modules.tar.gz"]))

      assert ehosctl(~w(server status), opts) == {0, "✓ status done.\n", ""}
      assert kept(home) == "0.5.0"

      # A release that no longer names that archive is refused, and nothing is changed.
      File.rm!(Path.join([home, "trial", "release", "ehos-modules.tar.gz"]))
      serve_releases(github, [release("0.5.0", modules(dir, "aws"))])

      assert ehosctl(~w(server status), opts) == {1, "", @modules_gone}
      assert kept(home) == "0.5.0"
    end

    test "take the newest release for a server made with Mix, and keep it", %{
      github: github,
      opts: opts,
      home: home,
      tmp_dir: dir
    } do
      made(home, "trial")
      serve_releases(github, [release("0.5.0", modules(dir))])

      assert ehosctl(~w(server status), opts) == {0, "✓ status done.\n", ""}

      assert platform_calls() == [
               status: platform_opts(home, "trial", source: source(home, "trial", "release"))
             ]

      assert kept(home) == "0.5.0"
    end

    test "need no release to close a tunnel", %{github: github, opts: opts, home: home} do
      made(home, "trial")
      FakeHTTP.down(github)

      assert ehosctl(~w(server tunnel --close), opts) == {0, "✓ close_tunnel done.\n", ""}
      assert platform_calls() == [close_tunnel: platform_opts(home, "trial", [])]
    end

    test "download nothing without the state's passphrase, which the platform then refuses", %{
      github: github,
      opts: opts,
      home: home
    } do
      made(home, "trial")
      FakeHTTP.down(github)
      stub_env(%{})
      opts = opts |> Keyword.delete(:passphrase)

      assert ehosctl(~w(server status), opts) == {0, "✓ status done.\n", ""}
      assert platform_calls() == [status: platform_opts(home, "trial", passphrase: nil)]
      refute File.exists?(Path.join([home, "trial", "release"]))
    end

    test "unpack the kept archive again only when modules/ is not known to be its", %{
      github: github,
      opts: opts,
      home: home,
      tmp_dir: dir
    } do
      serve_releases(github, [release("0.5.0", modules(dir))])
      {0, _stdout, ""} = ehosctl(~w(server up --provider oci), opts)
      made(home, "trial")
      main_tf = Path.join([home, "trial", "release", "modules", "deploy/tofu/oci/main.tf"])

      File.write!(main_tf, "# changed\n")
      assert ehosctl(~w(server status), opts) == {0, "✓ status done.\n", ""}
      assert File.read!(main_tf) == "# changed\n"

      File.rm!(Path.join([home, "trial", "release", "modules.sha256"]))
      assert ehosctl(~w(server status), opts) == {0, "✓ status done.\n", ""}
      assert File.read!(main_tf) == "# oci\n"
    end

    test "finish a keep that was interrupted between its renames", %{
      github: github,
      opts: opts,
      home: home,
      tmp_dir: dir
    } do
      serve_releases(github, [release("0.6.0", modules(dir)), release("0.5.0", modules(dir))])

      {0, _stdout, ""} = ehosctl(~w(server up --provider oci --version 0.6.0), opts)
      {0, _stdout, ""} = ehosctl(~w(server up --provider oci --version 0.5.0), opts)
      made(home, "trial")
      FakeHTTP.down(github)

      # As keep/1 leaves it when stopped after moving the old release aside: 0.5.0 is the new one.
      base = Path.join([home, "trial", "release"])
      File.rename!(base, base <> ".next")
      File.cp_r!(base <> ".next", base <> ".previous")

      File.write!(
        Path.join(base <> ".previous", "release.json"),
        File.read!(Path.join(base <> ".next", "release.json")) |> String.replace("0.5.0", "0.6.0")
      )

      assert ehosctl(~w(server status), opts) == {0, "✓ status done.\n", ""}
      assert kept(home) == "0.5.0"
      refute File.exists?(base <> ".previous") or File.exists?(base <> ".next")

      # Stopped with no new release beside it, the old one is put back.
      File.rename!(base, base <> ".previous")
      assert ehosctl(~w(server status), opts) == {0, "✓ status done.\n", ""}
      assert kept(home) == "0.5.0"
    end

    test "down says what is lost, and removes the server once the installation's name is typed",
         %{github: github, opts: opts, home: home, tmp_dir: dir} do
      serve_releases(github, [release("0.5.0", modules(dir, "aws"))])
      made(home, "acme")

      File.write!(
        Path.join([home, "acme", "installation.json"]),
        ~s({"provider": "aws", "region": "eu-central-1"})
      )

      current!(opts, "acme")
      mock_answer("acme\n")

      # ehosctl still knows the installation, and may keep a sign-in to it: a warning says how
      # to forget both if the server is not made again (ehos-tools#1016).
      assert ehosctl(~w(server down), opts) ==
               {0,
                """
                ✓ down done.

                ! ehosctl still knows the installation acme.
                  If you do not make the server again, remove your sign-in and the installation from ehosctl:
                    ehosctl logout --installation acme
                    ehosctl installations remove acme
                """, ""}

      assert_received {:asked, question}

      assert question ==
               """
               This removes the server of the installation acme on AWS in eu-central-1, permanently:
                 - the server ehos-acme and its disk, with the database of EHOS and the database of
                   each application on it;
                 - its network;
                 - its public address, which goes back to AWS, who can give it to anyone:
                   remove it from each rule that admits it, such as the rule of a mail relay.
               EHOS makes no backups yet, so you cannot get back what this removes.
               The installation acme serves https://ehos.example.org.

               """ <> "Type the name of the installation, acme, to remove its server: "

      assert platform_calls() == [
               down: platform_opts(home, "acme", source: source(home, "acme", "release"))
             ]
    end

    test "down takes --yes only with --installation on the command line, and then asks nothing",
         %{github: github, opts: opts, home: home, tmp_dir: dir} do
      made(home, "acme")
      mock_no_question()

      # Neither the current installation nor EHOSCTL_INSTALLATION names it for --yes.
      current!(opts, "acme")
      assert ehosctl(~w(server down --yes), opts) == {2, "", @yes_refused}

      stub_env(%{"EHOSCTL_INSTALLATION" => "acme"})
      assert ehosctl(~w(server down --yes), opts) == {2, "", @yes_refused}
      assert platform_calls() == []

      serve_releases(github, [release("0.5.0", modules(dir))])
      stub_env(%{})

      assert ehosctl(~w(server down --installation acme --yes), opts) ==
               {0,
                "✓ down done.\n\n! ehosctl still knows the installation acme.\n" <>
                  "  If you do not make the server again, remove your sign-in and the " <>
                  "installation from ehosctl:\n" <>
                  "    ehosctl logout --installation acme\n" <>
                  "    ehosctl installations remove acme\n", ""}

      assert platform_calls() == [
               down: platform_opts(home, "acme", source: source(home, "acme", "release"))
             ]
    end

    # A server made before Stage 13 is under `trial`, while the installation signed in to, and
    # current, is named after its host, too long to name a server (ehos-tools#194).
    test "with no server under the installation, refuse naming the installations that have " <>
           "one, before anything runs",
         %{opts: opts, home: home, github: github, tmp_dir: dir} do
      serve_releases(github, [release("0.6.0", modules(dir))])
      made(home, "trial")
      File.mkdir_p!(Path.join(home, "plugin-cache"))
      current!(opts, "ehos-92-5-148-138")

      for argv <- [~w(status), ~w(tunnel), ~w(tunnel --close), ~w(down --yes)] do
        assert ehosctl(["server" | argv], opts) ==
                 {2, "",
                  "ehosctl: This computer has no server for the installation " <>
                    "ehos-92-5-148-138 (the current installation). It has a server for the " <>
                    "installation trial. Run the command again with --installation trial.\n"}
      end

      made(home, "check")

      assert ehosctl(~w(server status --installation acme), opts) ==
               {2, "",
                "ehosctl: This computer has no server for the installation acme. It has " <>
                  "servers for the installations check, trial. Run the command again with " <>
                  "--installation and one of them.\n"}

      assert platform_calls() == []

      assert ehosctl(~w(server status --installation trial), opts) ==
               {0, "✓ status done.\n", ""}
    end

    test "with no server on this machine at all, refuse saying how to make one", %{
      opts: opts,
      home: home
    } do
      assert ehosctl(~w(server status), opts) ==
               {1, "",
                "ehosctl: This computer has no server for the installation trial (no " <>
                  "installation is named or current), or for another installation in #{home}. " <>
                  "Make one with `ehosctl server up --provider PROVIDER --installation trial`, " <>
                  "where PROVIDER is one of aws, gcp, oci, ovh.\n"}

      stub_env(%{"EHOSCTL_INSTALLATION" => "acme"})

      assert ehosctl(~w(server status), opts) ==
               {1, "",
                "ehosctl: This computer has no server for the installation acme " <>
                  "(EHOSCTL_INSTALLATION), or for another installation in #{home}. Make one " <>
                  "with `ehosctl server up --provider PROVIDER --installation acme`, where " <>
                  "PROVIDER is one of aws, gcp, oci, ovh.\n"}

      assert platform_calls() == []
    end

    test "refuse another --version than up kept", %{
      github: github,
      opts: opts,
      home: home,
      tmp_dir: dir
    } do
      serve_releases(github, [release("0.6.0", modules(dir)), release("0.5.0", modules(dir))])

      {0, _stdout, ""} = ehosctl(~w(server up --provider oci --version 0.5.0), opts)
      made(home, "trial")

      assert ehosctl(~w(server status --version 0.6.0), opts) ==
               {2, "",
                "ehosctl: This server was made from the modules of EHOS 0.5.0. To move " <>
                  "it to the modules of 0.6.0, run `ehosctl server up --installation trial " <>
                  "--version 0.6.0`.\n"}

      # A version that a shell would expand is quoted for one, and with a character a terminal
      # acts on, no command is offered.
      assert ehosctl(["server", "status", "--version", "x$(id)'y"], opts) ==
               {2, "",
                "ehosctl: This server was made from the modules of EHOS 0.5.0. To move " <>
                  "it to the modules of x$(id)'y, run `ehosctl server up --installation trial " <>
                  "--version 'x$(id)'\\''y'`.\n"}

      assert ehosctl(["server", "status", "--version", "x$(id)'\e"], opts) ==
               {2, "",
                "ehosctl: This server was made from the modules of EHOS 0.5.0. To move " <>
                  ~S|it to the modules of "x$(id)'\e", run `ehosctl server up --installation | <>
                  "trial` with --version.\n"}
    end

    # ehos-tools#430: a `y` out of habit, a wrong installation's name, or no answer, as a
    # script's stdin gives, removes nothing, downloads nothing, and fails so a script sees it.
    test "down removes nothing unless the installation's exact name is typed", %{
      github: github,
      opts: opts,
      home: home
    } do
      made(home, "acme")
      FakeHTTP.down(github)

      for answer <- ["y\n", "yes\n", "Acme\n", "trial\n", "acm\n", "\n", nil] do
        mock_answer(answer)

        assert ehosctl(~w(server down --installation acme), opts) ==
                 {1, "",
                  "ehosctl: ehosctl removed nothing, because you did not type the name of " <>
                    "the installation, acme. To remove its server, run `ehosctl server down " <>
                    "--installation acme` again.\n"}

        assert_received {:asked, question}

        assert question ==
                 """
                 This removes the server of the installation acme on Oracle Cloud, permanently:
                   - the server ehos-acme and its disk, with the database of EHOS and the database of
                     each application on it;
                   - its network;
                   - its public address, which goes back to Oracle Cloud, who can give it to anyone:
                     remove it from each rule that admits it, such as the rule of a mail relay.
                 EHOS makes no backups yet, so you cannot get back what this removes.

                 """ <> "Type the name of the installation, acme, to remove its server: "
      end

      assert platform_calls() == []
      refute File.exists?(Path.join([home, "acme", "release"]))
    end

    test "down refuses an installation that was never made, and asks nothing", %{
      opts: opts,
      home: home
    } do
      mock_no_question()

      assert ehosctl(~w(server down --installation acme), opts) ==
               {1, "",
                "ehosctl: This computer has no server for the installation acme, or for " <>
                  "another installation in #{home}. Make one with `ehosctl server up " <>
                  "--provider PROVIDER --installation acme`, where PROVIDER is one of aws, " <>
                  "gcp, oci, ovh.\n"}

      assert platform_calls() == []
    end

    test "take the options that size a server on up alone", %{opts: opts} do
      assert ehosctl(~w(server status --ocpus 1), opts) ==
               {2, "",
                """
                ehosctl: unrecognized arguments: "--ocpus", "1"

                See `ehosctl help server status`.
                """}
    end

    test "say how to go on when config.json cannot be read", %{
      opts: opts,
      home: home,
      github: github,
      tmp_dir: dir
    } do
      serve_releases(github, [release("0.6.0", modules(dir))])
      made(home, "trial")
      File.mkdir_p!(opts[:config_dir])
      File.write!(Path.join(opts[:config_dir], "config.json"), "{not json")

      assert ehosctl(~w(server status), opts) ==
               {1, "",
                "ehosctl: #{opts[:config_dir]}/config.json is not JSON. Correct or remove the " <>
                  "file. You can also name the installation with --installation or " <>
                  "EHOSCTL_INSTALLATION.\n"}

      assert ehosctl(~w(server status --installation trial), opts) ==
               {0, "✓ status done.\n", ""}
    end
  end

  # ehos-tools#197: EHOS's release command, which an operator ran with a line of kubectl.
  describe "server invite" do
    setup %{opts: opts, home: home} do
      # An invitation is refused under an installation no server's state is kept under
      # (ehos-tools#194).
      for name <- ~w(trial acme), do: made(home, name)

      answer_invite(
        {:ok, %{invited: @invited_line, link: @link, administrator: nil, interrupted: nil}}
      )

      # No passphrase and no release: the invitation needs neither.
      %{opts: opts |> Keyword.delete(:passphrase) |> Keyword.put(:install, Invite)}
    end

    test "prints EHOS's line, the link on a line of its own, and that the link is a password", %{
      opts: opts,
      home: home
    } do
      assert ehosctl(~w(server invite ada@example.com --installation acme), opts) ==
               {0,
                """
                ✓ #{@invited_line}

                    #{@link}
                """, link_is_a_password("acme")}

      assert_received {:invite, invited}
      assert invited == invitation(home, "acme")
    end

    test "says when the person became the platform's administrator, and when kubectl failed " <>
           "after the link",
         %{opts: opts, home: home} do
      administrator = "Nobody was administrator yet: ada@example.com is ehos.administrator now."

      answer_invite(
        {:ok,
         %{
           invited: @invited_line,
           link: @link,
           administrator: administrator,
           interrupted: {"kubectl failed after it.", "What EHOS said after it may be missing."}
         }}
      )

      assert ehosctl(~w(server invite ada@example.com), opts) ==
               {0,
                """
                ✓ #{@invited_line}

                    #{@link}

                #{administrator}
                """,
                link_is_a_password("trial") <>
                  "! kubectl failed after it.\n  What EHOS said after it may be missing.\n"}

      assert_received {:invite, invited}
      assert invited == invitation(home, "trial")
    end

    test "leaves out the command to disable the person when the address starts with a dash, " <>
           "which `people disable` would read as an option",
         %{opts: opts, home: home} do
      File.mkdir_p!(Path.join(home, "acme"))
      File.write!(Path.join([home, "acme", "kubeconfig"]), "{}")
      answer_kubectl({"#{@invited_line}\n#{@link}\n", 0})

      opts = opts |> Keyword.delete(:install) |> Keyword.put(:runner, Kubectl)

      {0, _stdout, stderr} =
        ehosctl(["server", "invite", "--yes@example.com", "--installation", "acme"], opts)

      assert stderr ==
               String.replace(
                 link_is_a_password("acme"),
                 "If another person possibly saw it, run `ehosctl people disable " <>
                   "ada@example.com --installation acme`.",
                 "If another person possibly saw it, disable the person with " <>
                   "`ehosctl people disable --installation acme`."
               )
    end

    test "writes the address into what EHOS evaluates as a string, through the installation's " <>
           "kubeconfig",
         %{opts: opts, home: home} do
      File.mkdir_p!(Path.join(home, "acme"))
      File.write!(Path.join([home, "acme", "kubeconfig"]), "{}")
      answer_kubectl({"#{@invited_line}\n#{@link}\n", 0})

      opts = opts |> Keyword.delete(:install) |> Keyword.put(:runner, Kubectl)
      email = ~S|a")<>throw(:injected)<>("@example.com|

      # Quoted, so that a shell passes it as one argument.
      assert ehosctl(["server", "invite", email, "--installation", "acme"], opts) ==
               {0,
                """
                ✓ #{@invited_line}

                    #{@link}
                """, link_is_a_password(~S|'a")<>throw(:injected)<>("@example.com'|, "acme")}

      assert_received {:kubectl, args}

      assert args == [
               "--kubeconfig",
               Path.join([home, "acme", "kubeconfig"]),
               "--context",
               "ehos-acme",
               "--namespace",
               "ehos-system",
               "exec",
               "deployment/ehos-governance",
               "--container",
               "governance",
               "--",
               "bin/ehos",
               "eval",
               ~S|Ehos.Release.invite("a\")<>throw(:injected)<>(\"@example.com")|
             ]
    end

    test "is listed in the help, which says the link is a password", %{opts: opts} do
      assert ehosctl(~w(server --help), opts) == {0, server_help(), ""}
      {0, help, ""} = ehosctl(~w(server invite --help), opts)

      assert help == """
             ehosctl #{Ehosctl.version()}
             Print a link that signs a person in one time, within 15 minutes. It invites a new person. If the platform has no administrator, the person becomes it. The link is a password. The command goes through the tunnel that `ehosctl server tunnel` opens.

             USAGE:
                 ehosctl server invite [--installation NAME] EMAIL

             ARGS:

                 EMAIL        The email of a new person, or of a person who forgot their
                              password.

             OPTIONS:

                 --installation        The installation of the server. By default
                                       EHOSCTL_INSTALLATION, else the current installation,
                                       else trial.

             Plane: platform. This command acts with an account that EHOS does not issue: an account of a cloud provider, an SSH key or a kubeconfig.

             """
    end

    test "refuses an installation no server's state is kept under, before inviting", %{opts: opts} do
      assert ehosctl(~w(server invite ada@example.com --installation ghost), opts) ==
               {2, "",
                "ehosctl: This computer has no server for the installation ghost. It has " <>
                  "servers for the installations acme, trial. Run the command again with " <>
                  "--installation and one of them.\n"}

      refute_received {:invite, _opts}
    end

    test "refuses an address EHOS would refuse before anything runs", %{opts: opts} do
      not_an_address =
        "is not an email address EHOS takes: one @ with something on each side, and no " <>
          "space, comma or semicolon"

      for {email, refusal} <- [
            {"ada@example.com,alan@example.com",
             ~s("ada@example.com,alan@example.com" #{not_an_address})},
            {"ada", ~s("ada" #{not_an_address})},
            {"ada\e[2J@example.com",
             ~S("ada\e[2J@example.com") <>
               " is not an email address EHOS takes: it holds bytes that are not UTF-8, a " <>
               "control or formatting character, or a space"}
          ] do
        assert ehosctl(["server", "invite", email], opts) == {2, "", "ehosctl: #{refusal}\n"}
        refute_received {:invite, _opts}
      end
    end

    test "says why it could not invite, and exits 1", %{opts: opts} do
      answer_invite({:error, "EHOS did not invite ada@example.com: (ArgumentError) no"})

      assert ehosctl(~w(server invite ada@example.com), opts) ==
               {1, "", "ehosctl: EHOS did not invite ada@example.com: (ArgumentError) no\n"}
    end
  end

  describe "what the platform says" do
    test "is printed in its shapes: the outcome, its values, what a program printed, and next",
         %{opts: opts, home: home, github: github, tmp_dir: dir} do
      serve_releases(github, [release("0.6.0", modules(dir))])
      made(home, "trial")

      answer_platform(
        :status,
        {:ok,
         %EhosPlatform.Report{
           outcome: "The server ehos-trial answered.",
           values: [
             {"Address", "203.0.113.10"},
             {"SSH host key", "ssh-ed25519 SHA256:abc\nTrusted on first contact."}
           ],
           tool_output: [{"kubectl get nodes", "NAME   STATUS\nehos   Ready\n"}],
           next: ["ehosctl server tunnel --installation trial"]
         }}
      )

      assert ehosctl(~w(server status), opts) ==
               {0,
                """
                ✓ The server ehos-trial answered.
                  Address        203.0.113.10
                  SSH host key   ssh-ed25519 SHA256:abc
                                 Trusted on first contact.

                kubectl get nodes printed:
                  NAME   STATUS
                  ehos   Ready

                Next:
                  ehosctl server tunnel --installation trial
                """, ""}
    end

    test "names the secrets of a run, with a warning for one that is new",
         %{opts: opts, home: home, github: github, tmp_dir: dir} do
      serve_releases(github, [release("0.6.0", modules(dir))])
      made(home, "trial")
      kubeconfig = Path.join([home, "trial", "kubeconfig"])

      answer_platform(
        :tunnel,
        {:ok,
         %EhosPlatform.Report{
           outcome: "The tunnel to the API server of ehos-trial is open.",
           values: [{"Address", "127.0.0.1:16443"}],
           secrets: [
             %EhosPlatform.Secret{kind: :ssh_key, place: "/home/a/.ssh/ehos_oci"},
             %EhosPlatform.Secret{kind: :kubeconfig, place: kubeconfig, new?: true}
           ]
         }}
      )

      assert ehosctl(~w(server tunnel), opts) ==
               {0,
                """
                ✓ The tunnel to the API server of ehos-trial is open.
                  Address      127.0.0.1:16443
                  SSH key      /home/a/.ssh/ehos_oci
                  Kubeconfig   #{kubeconfig}

                ! The kubeconfig gives administrator access to the cluster until its certificate expires, within 12 hours.
                  Keep it to yourself. Do not share it. Do not copy it: ehosctl server tunnel writes it again.
                """, ""}
    end

    test "names up's secrets, warning of each shared one when up changed the server", %{
      opts: opts,
      home: home,
      github: github,
      tmp_dir: dir
    } do
      serve_releases(github, [release("0.6.0", modules(dir))])

      share =
        "https://github.com/EmpoweredHouse/eh-os/blob/main/docs/INSTALLING.md#share-an-installation-with-another-installation-administrator"

      secrets = fn new? ->
        [
          %EhosPlatform.Secret{
            kind: :state_passphrase,
            place: "EHOS_STATE_PASSPHRASE",
            new?: new?
          },
          %EhosPlatform.Secret{
            kind: :encrypted_state,
            place: "/h/trial/terraform.tfstate",
            new?: new?
          },
          %EhosPlatform.Secret{kind: :shared_ssh_key, place: "/h/.ssh/ehos_oci", new?: new?}
        ]
      end

      values = """
      ✓ The server ehos-trial is up, with k3s.
        Address            203.0.113.10
        State passphrase   EHOS_STATE_PASSPHRASE
        Encrypted state    /h/trial/terraform.tfstate
        Shared SSH key     /h/.ssh/ehos_oci
      """

      answer_platform(:up, fn _opts ->
        File.mkdir_p!(Path.join(home, "trial"))

        {:ok,
         %EhosPlatform.Report{
           outcome: "The server ehos-trial is up, with k3s.",
           values: [{"Address", "203.0.113.10"}],
           secrets: secrets.(Process.get(:changed?, true))
         }}
      end)

      {0, changed, ""} = ehosctl(~w(server up --provider oci), opts)

      assert changed ==
               values <>
                 """

                 ! Without the state passphrase, ehosctl cannot change or remove the server.
                   Keep it in the password manager that the installation administrators share.
                   The installation guide says how: #{share}

                 ! Without a current copy of the state, ehosctl cannot change or remove the server.
                   Keep it in the password manager that the installation administrators share. Copy it again after each ehosctl server up.
                   The installation guide says how: #{share}

                 ! The shared SSH key gives a shell on the server, as root, to each person who holds it.
                   Keep it in the password manager that the installation administrators share. Move to keys of your own: ehosctl server admin add for each person, then ehosctl server admin remove shared.
                   The installation guide says how: #{share}
                 """

      Process.put(:changed?, false)
      assert ehosctl(~w(server up --provider oci), opts) == {0, values, ""}
    end

    test "a failure shows what the program printed under its name", %{
      opts: opts,
      home: home,
      github: github,
      tmp_dir: dir
    } do
      serve_releases(github, [release("0.6.0", modules(dir))])
      made(home, "trial")

      answer_platform(
        :tunnel,
        {:error,
         EhosPlatform.Failure.new(
           "`ssh` could not open the tunnel (exit status 255).",
           "ssh",
           "bind [127.0.0.1]:16443: Address already in use\n"
         )}
      )

      assert ehosctl(~w(server tunnel), opts) ==
               {1, "",
                """
                ehosctl: `ssh` could not open the tunnel (exit status 255).
                ssh printed:
                  bind [127.0.0.1]:16443: Address already in use
                """}
    end

    test "while it runs is on stderr, a wait with the whole minutes it has lasted", %{
      opts: opts,
      home: home,
      github: github,
      tmp_dir: dir
    } do
      serve_releases(github, [release("0.6.0", modules(dir))])
      made(home, "trial")

      answer_platform(:status, fn platform_opts ->
        say = platform_opts[:progress]
        say.({:step, "Opening the tunnel to 203.0.113.10"})
        for elapsed <- [0, 75_000, 125_000], do: say.({:waiting, "Waiting for SSH.", elapsed})
        say.({:warning, "The first boot finished with recoverable errors.", nil})
        say.({:tool_output, "cloud-init status --long", "status: done\n"})
        say.({:warning, "The key is another.", "The server can refuse it."})
        {:ok, %EhosPlatform.Report{outcome: "No tunnel is open.", ending: :unchanged}}
      end)

      assert ehosctl(~w(server status), opts) ==
               {0, "· No tunnel is open.\n",
                """
                ==> Opening the tunnel to 203.0.113.10
                ==> Waiting for SSH.
                ==> The wait has lasted 1 minute
                ==> The wait has lasted 2 minutes
                ! The first boot finished with recoverable errors.
                cloud-init status --long printed:
                  status: done
                ! The key is another.
                  The server can refuse it.
                """}
    end

    test "after an up whose release ehosctl could not keep is said with what to run", %{
      opts: opts,
      home: home,
      github: github,
      tmp_dir: dir
    } do
      serve_releases(github, [release("0.5.0", modules(dir))])

      # The release downloaded for this `up` is gone by the time `up` has applied it.
      answer_platform(:up, fn _opts ->
        File.rm_rf!(Path.join([home, "trial", "release.next"]))
        {:ok, %EhosPlatform.Report{outcome: "The server ehos-trial is up, with k3s."}}
      end)

      assert ehosctl(~w(server up --provider oci), opts) ==
               {1, "",
                not_kept(home, "`up` made the server:\n✓ The server ehos-trial is up, with k3s.")}
    end

    test "after an up that failed once it changed the state is said with the failure", %{
      opts: opts,
      home: home,
      github: github,
      tmp_dir: dir
    } do
      serve_releases(github, [release("0.5.0", modules(dir))])

      answer_platform(:up, fn _opts ->
        File.write!(Path.join([home, "trial", "terraform.tfstate"]), "applied")
        File.rm_rf!(Path.join([home, "trial", "release.next"]))
        {:error, "The server's first boot did not finish cleanly."}
      end)

      assert ehosctl(~w(server up --provider oci), opts) ==
               {1, "",
                not_kept(
                  home,
                  "After the apply, `up` failed: The server's first boot did not finish cleanly."
                )}
    end
  end

  # What `server up` says when it made the server `trial` from release 0.5.0 and could not keep
  # the release, and then what `up` said.
  defp not_kept(home, said) do
    """
    ehosctl: ehosctl could not keep the modules in #{home}/trial/release.next that made the \
    server. #{home}/trial/release: ehosctl cannot keep the release there (no such file or \
    directory).
    What to do:
      To keep them, run:
      ehosctl server up --installation trial --version 0.5.0

    #{said}
    """
  end

  describe "server" do
    test "says in its help that it is on the platform plane", %{opts: opts} do
      assert ehosctl(~w(server --help), opts) == {0, server_help(), ""}
    end
  end

  # What the platform was asked since the last call, oldest first, each `{function, options}`
  # with the options as a map. Its progress, a function, is left out: no test can name it.
  defp platform_calls do
    receive do
      {:platform, fun, opts} ->
        [{fun, opts |> Map.new() |> Map.delete(:progress)} | platform_calls()]
    after
      0 -> []
    end
  end

  defp administrators_calls do
    receive do
      {:administrators, call, opts} -> [{call, opts} | administrators_calls()]
    after
      0 -> []
    end
  end

  # Makes the platform's `fun` answer `answer`, or as it does by default for `nil`.
  defp answer_platform(fun, nil), do: Process.delete({Platform, fun})
  defp answer_platform(fun, answer), do: Process.put({Platform, fun}, answer)

  defp answer_invite(answer), do: Process.put({Invite, :invite}, answer)

  defp answer_kubectl(answer), do: Process.put({Kubectl, :answer}, answer)

  # What the platform is asked to do with the server `name` in `home`: what every command gives,
  # with `fields` over it.
  defp platform_opts(home, name, fields) do
    Map.merge(
      %{
        name: name,
        home: home,
        ssh_from: [],
        replace: false,
        public_certificates: false,
        runner: Ehosctl.PlatformRunner,
        command: "ehosctl server",
        release_option: "--version",
        name_option: "--installation",
        name_in_commands: true,
        passphrase: @passphrase
      },
      Map.new(fields)
    )
  end

  # The release's chart, and its modules as unpacked under `release` (`release` or
  # `release.next`) of the server `name`.
  defp source(home, name, release),
    do: %EhosPlatform.Source{
      chart: {:oci, @chart},
      modules: Path.join([home, name, release, "modules"])
    }

  # What `EhosPlatform.Install` is asked, to invite ada@example.com through the server `name`.
  defp invitation(home, name) do
    [
      email: "ada@example.com",
      name: name,
      home: home,
      runner: Ehosctl.PlatformRunner,
      server_command: "ehosctl server",
      name_option: "--installation",
      name_in_commands: true
    ]
  end

  # The warning on stderr, before the link: T-30's for the link, with what to do here.
  defp link_is_a_password(email \\ "ada@example.com", name) do
    "! The link is a password: it signs in as that person one time, within 15 minutes.\n" <>
      "  Give it only to that person. Send it in a direct message to an account that you know " <>
      "is theirs. Do not put it in a channel, a ticket or a thread that others read. A new link " <>
      "does not end it. If another person possibly saw it, run `ehosctl people disable " <>
      "#{email} --installation #{name}`. This ends each link of the person. Then enable the " <>
      "person and run this command again. Nobody can disable the only administrator of the " <>
      "platform: that person must open the link at once, which uses it.\n"
  end

  defp server_help do
    """
    ehosctl #{Ehosctl.version()}
    Make, reach, read and remove the server of an installation in Oracle Cloud, AWS, GCP or OVHcloud. Add and remove its installation administrators. Invite a person through the server, and print what to hand over to another installation administrator.

    USAGE:
        ehosctl server

    SUBCOMMANDS:

        up              Make the server, or change it to match the modules, and wait
                        until k3s runs.
        tunnel          Open an SSH tunnel to the Kubernetes API of the server, and
                        write its kubeconfig. If you are an installation
                        administrator, the kubeconfig holds a key of your own and a
                        certificate for 12 hours.
        status          Show the address, CPUs, memory and load of the server, its
                        first boot and its node. It works when EHOS is stopped.
        down            Remove the server and all that was made with it, after you
                        type the name of the installation. You cannot get back what
                        it removes.
        invite          Print a link that signs a person in one time, within 15
                        minutes. It invites a new person. If the platform has no
                        administrator, the person becomes it. The link is a
                        password. The command goes through the tunnel that `ehosctl
                        server tunnel` opens.
        admin           Add, remove and list the installation administrators of the
                        server. Each one logs in with an SSH key of their own and
                        has a ClusterRoleBinding of their own. ehosctl changes the
                        server over SSH. It needs the state passphrase, and no cloud
                        credential.
        handover        Print what another installation administrator needs to take
                        over the installation, and the commands that each of you
                        runs. ehosctl contacts nothing, changes nothing and shows no
                        secret.

    Plane: platform. This command acts with an account that EHOS does not issue: an account of a cloud provider, an SSH key or a kubeconfig.

    """
  end

  defp serve_releases(github, releases),
    do: FakeGitHub.releases(github, "EmpoweredHouse/eh-os", releases)

  # An archive of the modules, as eh-os's release attaches it, and its SHA-256.
  defp modules(dir, provider \\ "oci") do
    path = Path.join(dir, "modules-#{System.unique_integer([:positive])}.tar.gz")

    :ok =
      :erl_tar.create(
        String.to_charlist(path),
        [{~c"deploy/tofu/#{provider}/main.tf", "# #{provider}\n"}],
        [:compressed]
      )

    bytes = File.read!(path)
    {bytes, :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)}
  end

  defp release(version, {archive, sha256}) do
    {"v#{version}",
     %{
       "assets" => %{
         "release.json" => %{
           "schema" => "ehos.release/v1",
           "component" => "ehos",
           "version" => version,
           "chart" => @chart,
           "modules" => %{"asset" => "ehos-modules.tar.gz", "sha256" => sha256}
         },
         "ehos-modules.tar.gz" => archive
       }
     }}
  end

  defp kept(home, name \\ "trial"),
    do: Ehosctl.ServerRelease.kept_version(Path.join([home, name, "release"]))

  defp current!(opts, name) do
    :ok =
      Config.write(
        %Config{current: name, installations: %{name => %{"url" => "https://ehos.example.org"}}},
        opts[:config_dir]
      )
  end

  # In place of the question: says what was asked, and gives `answer`.
  # The person types `answer`, or nothing, as a script's stdin gives, with `nil`.
  defp mock_answer(answer) do
    test = self()

    stub(Ehosctl.TerminalMock, :gets, fn question ->
      send(test, {:asked, question})
      answer
    end)
  end

  defp mock_no_question, do: expect(Ehosctl.TerminalMock, :gets, 0, fn _question -> nil end)

  defp made(home, name) do
    File.mkdir_p!(Path.join(home, name))
    File.write!(Path.join([home, name, "server.tfvars.json"]), "{}")
    File.write!(Path.join([home, name, "installation.json"]), ~s({"provider": "oci"}))
  end
end
