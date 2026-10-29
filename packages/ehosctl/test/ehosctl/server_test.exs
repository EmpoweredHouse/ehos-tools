defmodule Ehosctl.ServerTest do
  # Not async: capture_io(:stderr) captures stderr for every process.
  use Ehosctl.Case, async: false

  import ExUnit.CaptureIO

  alias Ehosctl.Config
  alias Ehosctl.FakeGitHub
  alias Ehosctl.FakeHTTP

  @moduletag :tmp_dir

  # In place of `EhosPlatform.Server`: says what it was asked, with which options, and answers.
  defmodule Platform do
    @moduledoc false

    # A test makes one fail with `Process.put({Platform, fun}, {:error, message})`.
    for fun <- [:up, :down, :status, :tunnel, :close_tunnel] do
      def unquote(fun)(opts) do
        send(self(), {:platform, unquote(fun), opts})

        case Process.get({__MODULE__, unquote(fun)}, {:ok, "#{unquote(fun)} done"}) do
          answer when is_function(answer, 1) -> answer.(opts)
          answer -> answer
        end
      end
    end

    defdelegate made?(opts), to: EhosPlatform.Server
  end

  @chart "oci://ghcr.io/empoweredhouse/charts/ehos@sha256:" <> String.duplicate("a", 64)

  setup %{tmp_dir: dir} do
    github = FakeGitHub.start()

    opts =
      [
        server: Platform,
        home: Path.join(dir, "ehos"),
        config_dir: Path.join(dir, "config"),
        passphrase: String.duplicate("p", 16)
      ]

    %{github: github, opts: opts, home: Path.join(dir, "ehos")}
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

  defp made(home, name) do
    File.mkdir_p!(Path.join(home, name))
    File.write!(Path.join([home, name, "server.tfvars.json"]), "{}")
    File.write!(Path.join([home, name, "installation.json"]), ~s({"provider": "oci"}))
  end

  describe "the installation" do
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

    test "is refused before anything runs when the OpenTofu module would refuse it", %{
      opts: opts
    } do
      {2, "", stderr} =
        ehosctl(["server", "up", "--installation", "a-name-longer-than-sixteen"], opts)

      assert stderr =~ "cannot name a server: The installation's name is 2 to 16"
      refute_received {:platform, _fun, _opts}
    end

    # A server made before Stage 13 is under `trial`, while the installation signed in to, and
    # current, is named after its host, too long to name a server (#194).
    test "with no server under it, is refused naming the installations that have one, before " <>
           "anything runs",
         %{opts: opts, home: home, github: github, tmp_dir: dir} do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [release("0.6.0", modules(dir))])
      made(home, "trial")
      File.mkdir_p!(Path.join(home, "plugin-cache"))
      current!(opts, "ehos-92-5-148-138")

      for argv <- [~w(status), ~w(tunnel), ~w(tunnel --close), ~w(down --yes)] do
        {2, "", stderr} = ehosctl(["server" | argv], opts)

        assert stderr =~
                 "No server is known under ehos-92-5-148-138 (the current installation); the " <>
                   "one on this machine is trial's. Run the command again with --installation " <>
                   "trial."
      end

      made(home, "check")
      {2, "", stderr} = ehosctl(~w(server status --installation acme), opts)

      assert stderr =~
               "No server is known under acme; servers on this machine: check, trial. Run the " <>
                 "command again with --installation and one of them."

      refute_received {:platform, _fun, _opts}
      {0, "status done\n", ""} = ehosctl(~w(server status --installation trial), opts)
    end

    test "with no server on this machine at all, is refused saying how to make one", %{
      opts: opts
    } do
      {1, "", stderr} = ehosctl(~w(server status), opts)

      assert stderr =~
               "No server is known under trial (no installation is named or current), nor " <>
                 "under any other installation in "

      assert stderr =~
               "Make one with `ehosctl server up --provider PROVIDER --installation trial`, PROVIDER one of aws, gcp, oci, ovh."

      stub_env(%{"EHOSCTL_INSTALLATION" => "acme"})
      {1, "", stderr} = ehosctl(~w(server status), opts)
      assert stderr =~ "No server is known under acme (EHOSCTL_INSTALLATION), nor"
      refute_received {:platform, _fun, _opts}
    end

    test "up makes no new server under the current installation's name while another has one",
         %{opts: opts, home: home, github: github, tmp_dir: dir} do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [release("0.6.0", modules(dir))])
      made(home, "trial")
      current!(opts, "acme")

      {2, "", stderr} = ehosctl(~w(server up --provider oci), opts)

      assert stderr =~
               "No server is known under acme (the current installation); the one on this " <>
                 "machine is trial's. `up` makes a new server only under a name it is given: " <>
                 "run it again with --installation trial to bring that server in line, or with " <>
                 "--installation acme --provider PROVIDER (aws, gcp, oci, ovh) to make a new one."

      current!(opts, "ehos-92-5-148-138")
      {2, "", stderr} = ehosctl(~w(server up --provider oci), opts)
      assert stderr =~ "or with a name of its own to make a new one (The installation's name is"
      refute_received {:platform, :up, _opts}

      {0, "up done\n", ""} = ehosctl(~w(server up --provider oci --installation acme), opts)
      assert_received {:platform, :up, up}
      assert up[:name] == "acme"
    end

    test "up makes no new trial server, when no installation is named or current, while " <>
           "another has one",
         %{opts: opts, home: home, github: github, tmp_dir: dir} do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [release("0.6.0", modules(dir))])
      made(home, "acme")

      {2, "", stderr} = ehosctl(~w(server up --provider oci), opts)

      assert stderr =~
               "No server is known under trial (no installation is named or current); the one " <>
                 "on this machine is acme's. `up` makes a new server only under a name it is " <>
                 "given: run it again with --installation acme to bring that server in line, " <>
                 "or with --installation trial --provider PROVIDER (aws, gcp, oci, ovh) to make a new one."

      refute_received {:platform, :up, _opts}

      {0, "up done\n", ""} = ehosctl(~w(server up --provider oci --installation trial), opts)
      assert_received {:platform, :up, up}
      assert up[:name] == "trial"
    end

    test "up makes the first server under the current installation's name", %{
      opts: opts,
      github: github,
      tmp_dir: dir
    } do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [release("0.6.0", modules(dir))])
      current!(opts, "acme")

      {0, "up done\n", ""} = ehosctl(~w(server up --provider oci), opts)
      assert_received {:platform, :up, up}
      assert up[:name] == "acme"
    end

    # Run as printed, a command that left the installation out would reach whichever is current
    # by then (#194).
    test "is named in every command the platform suggests", %{
      opts: opts,
      home: home,
      github: github,
      tmp_dir: dir
    } do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [release("0.6.0", modules(dir))])
      made(home, "trial")
      {0, _stdout, ""} = ehosctl(~w(server status), opts)
      assert_received {:platform, :status, status}

      assert status[:command] == "ehosctl server" and status[:name_option] == "--installation"
      assert status[:name_in_commands] == true
    end
  end

  describe "up" do
    # #345: a damaged record is a failure, exit 1, not a usage error.
    test "fails, rather than refusing the command line, when the installation's record is damaged",
         %{opts: opts, home: home} do
      made(home, "trial")
      File.write!(Path.join([home, "trial", "installation.json"]), "{")

      {1, "", stderr} = ehosctl(~w(server up), opts)
      assert stderr =~ "cannot be read as an installation's place"
      refute_received {:platform, :up, _opts}
    end

    # eh-os D-126: no cloud is chosen for the operator, and nothing is downloaded for an `up` that
    # will be refused for it.
    test "downloads no release for a server not made yet when no --provider names its cloud", %{
      github: github,
      opts: opts,
      home: home,
      tmp_dir: dir
    } do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [release("0.6.0", modules(dir))])

      {2, "", stderr} = ehosctl(~w(server up), opts)

      assert stderr =~ "--provider aws, gcp, oci, ovh"
      refute_received {:platform, :up, _opts}
      refute File.exists?(Path.join([home, "trial", "release.next"]))
      assert kept(home) == nil

      {0, "up done\n", ""} = ehosctl(~w(server up --provider aws), opts)
      assert_received {:platform, :up, up}
      assert up[:provider] == "aws"
      assert %EhosPlatform.Source{} = up[:source]
    end

    test "makes the server from the newest release's modules, checked, and keeps them", %{
      github: github,
      opts: opts,
      home: home,
      tmp_dir: dir
    } do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [
        release("0.6.0", modules(dir)),
        release("0.5.0", modules(dir))
      ])

      argv =
        ~w(server up --provider oci --ssh-from 192.0.2.1 --ssh-from 198.51.100.0/24 --ocpus 1 --replace)

      {0, "up done\n", ""} = ehosctl(argv, opts)

      assert_received {:platform, :up, up}
      assert up[:name] == "trial"
      assert up[:home] == Path.join(dir, "ehos")
      assert up[:ssh_from] == ["192.0.2.1", "198.51.100.0/24"]
      assert up[:ocpus] == 1 and up[:replace] == true
      assert up[:runner] == Ehosctl.PlatformRunner
      assert up[:command] == "ehosctl server" and up[:name_option] == "--installation"

      assert %EhosPlatform.Source{chart: {:oci, @chart}, modules: modules} = up[:source]
      # Planned from where it was checked, and kept once `up` succeeded.
      assert modules == Path.join([home, "trial", "release.next", "modules"])
      kept = Path.join([home, "trial", "release", "modules", "deploy/tofu/oci/main.tf"])
      assert File.read!(kept) == "# oci\n"
      assert Ehosctl.ServerRelease.kept_version(Path.join([home, "trial", "release"])) == "0.6.0"
    end

    test "takes the release --version names", %{
      github: github,
      opts: opts,
      home: home,
      tmp_dir: dir
    } do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [
        release("0.6.0", modules(dir)),
        release("0.5.0", modules(dir))
      ])

      {0, _stdout, ""} = ehosctl(~w(server up --provider oci --version 0.5.0), opts)
      assert Ehosctl.ServerRelease.kept_version(Path.join([home, "trial", "release"])) == "0.5.0"

      {2, "", stderr} = ehosctl(~w(server up --provider oci --version 0.4.0), opts)
      assert stderr =~ "EHOS has no release 0.4.0"
    end

    test "refuses a modules' archive whose SHA-256 is not the one release.json names, and keeps " <>
           "the release it had",
         %{github: github, opts: opts, home: home, tmp_dir: dir} do
      {archive, _sha256} = modules(dir)

      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [
        release("0.6.0", {archive, String.duplicate("0", 64)}),
        release("0.5.0", modules(dir))
      ])

      {0, _stdout, ""} = ehosctl(~w(server up --provider oci --version 0.5.0), opts)
      assert_received {:platform, :up, _opts}

      {1, "", stderr} = ehosctl(~w(server up --provider oci --version 0.6.0), opts)
      assert stderr =~ "SHA-256"
      refute_received {:platform, :up, _opts}
      assert kept(home) == "0.5.0"
      refute File.exists?(Path.join([home, "trial", "release.next"]))

      # And the kept release still makes the server, with no download.
      FakeHTTP.down(github)
      {0, "up done\n", ""} = ehosctl(~w(server up --provider oci), opts)
    end

    test "keeps a release it downloaded only once up has succeeded", %{
      github: github,
      opts: opts,
      home: home,
      tmp_dir: dir
    } do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [
        release("0.6.0", modules(dir)),
        release("0.5.0", modules(dir))
      ])

      {0, _stdout, ""} = ehosctl(~w(server up --provider oci --version 0.5.0), opts)

      Process.put({Platform, :up}, {:error, "the plan would replace the server"})
      {1, "", stderr} = ehosctl(~w(server up --provider oci --version 0.6.0), opts)
      assert stderr =~ "the plan would replace the server"
      assert_received {:platform, :up, up}
      assert up[:source].modules == Path.join([home, "trial", "release.next", "modules"])
      assert kept(home) == "0.5.0"
      refute File.exists?(Path.join([home, "trial", "release.next"]))

      Process.delete({Platform, :up})
      {0, "up done\n", ""} = ehosctl(~w(server up --provider oci --version 0.6.0), opts)
      assert kept(home) == "0.6.0"
    end

    test "keeps a release whose apply was reached, though what came after it failed", %{
      github: github,
      opts: opts,
      home: home,
      tmp_dir: dir
    } do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [
        release("0.6.0", modules(dir)),
        release("0.5.0", modules(dir))
      ])

      {0, _stdout, ""} = ehosctl(~w(server up --provider oci --version 0.5.0), opts)

      Process.put({Platform, :up}, fn up ->
        File.write!(Path.join(EhosPlatform.Server.dir(up), "terraform.tfstate"), "applied")
        {:error, "The server's first boot did not finish cleanly"}
      end)

      {1, "", _stderr} = ehosctl(~w(server up --provider oci --version 0.6.0), opts)
      assert kept(home) == "0.6.0"
    end

    test "refuses to guess which release to plan with when the kept one cannot be read", %{
      github: github,
      opts: opts,
      home: home,
      tmp_dir: dir
    } do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [
        release("0.6.0", modules(dir)),
        release("0.5.0", modules(dir))
      ])

      {0, _stdout, ""} = ehosctl(~w(server up --provider oci --version 0.5.0), opts)
      made(home, "trial")
      file = Path.join([home, "trial", "release", "release.json"])
      File.write!(file, File.read!(file) |> String.replace(~s("0.5.0"), ~s("0.5.0\\u001b[2J")))

      for command <- ~w(up status) do
        {1, "", stderr} = ehosctl(["server", command, "--provider", "oci"], opts)
        assert stderr =~ "is missing or is not a release's"

        assert stderr =~
                 "`ehosctl server up --installation trial --version <the server's release>`"

        refute stderr =~ "\e"
      end

      {0, "up done\n", ""} = ehosctl(~w(server up --provider oci --version 0.5.0), opts)
      assert kept(home) == "0.5.0"
    end

    test "up takes the kept version again only if it still names the same archive", %{
      github: github,
      opts: opts,
      home: home,
      tmp_dir: dir
    } do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [release("0.5.0", modules(dir))])
      {0, _stdout, ""} = ehosctl(~w(server up --provider oci), opts)
      assert_received {:platform, :up, _opts}
      File.rm!(Path.join([home, "trial", "release", "ehos-modules.tar.gz"]))
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [release("0.5.0", modules(dir, "aws"))])

      {1, "", stderr} = ehosctl(~w(server up --provider oci), opts)
      assert stderr =~ "no longer names the modules this server was made from"
      refute_received {:platform, :up, _opts}
    end

    test "without --version, keeps to the release kept, though a newer one is out", %{
      github: github,
      opts: opts,
      home: home,
      tmp_dir: dir
    } do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [
        release("0.6.0", modules(dir)),
        release("0.5.0", modules(dir))
      ])

      {0, _stdout, ""} = ehosctl(~w(server up --provider oci --version 0.5.0), opts)
      {0, _stdout, ""} = ehosctl(~w(server up --provider oci), opts)
      assert kept(home) == "0.5.0"
    end

    test "refuses a release that names no modules", %{github: github, opts: opts} do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [
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

      {1, "", stderr} = ehosctl(~w(server up --provider oci), opts)
      assert stderr =~ "v0.4.0 names no chart and modules"
    end
  end

  describe "status, tunnel and down" do
    test "plan against the release up kept, without asking GitHub", %{
      github: github,
      opts: opts,
      home: home,
      tmp_dir: dir
    } do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [release("0.5.0", modules(dir))])
      {0, _stdout, ""} = ehosctl(~w(server up --provider oci), opts)
      made(home, "trial")

      # A newer release is out, and then GitHub no longer answers: neither changes the modules.
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [
        release("0.6.0", modules(dir)),
        release("0.5.0", modules(dir))
      ])

      FakeHTTP.down(github)

      {0, "status done\n", ""} = ehosctl(~w(server status), opts)
      assert_received {:platform, :status, status}
      assert status[:source].modules == Path.join([home, "trial", "release", "modules"])

      {0, "tunnel done\n", ""} = ehosctl(~w(server tunnel --port 16500), opts)
      assert_received {:platform, :tunnel, tunnel}
      assert tunnel[:port] == 16_500

      {0, "down done\n", ""} = ehosctl(~w(server down --installation trial --yes), opts)
      assert_received {:platform, :down, down}
      assert down[:source].modules == status[:source].modules
      assert kept(home) == "0.5.0"
    end

    test "download the kept release again when its archive is gone, and only that one", %{
      github: github,
      opts: opts,
      home: home,
      tmp_dir: dir
    } do
      kept_modules = modules(dir)

      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [
        release("0.6.0", modules(dir)),
        release("0.5.0", kept_modules)
      ])

      {0, _stdout, ""} = ehosctl(~w(server up --provider oci --version 0.5.0), opts)
      made(home, "trial")
      File.rm!(Path.join([home, "trial", "release", "ehos-modules.tar.gz"]))

      {0, "status done\n", ""} = ehosctl(~w(server status), opts)
      assert kept(home) == "0.5.0"

      # A release that no longer names that archive is refused, and nothing is changed.
      File.rm!(Path.join([home, "trial", "release", "ehos-modules.tar.gz"]))
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [release("0.5.0", modules(dir, "aws"))])

      {1, "", stderr} = ehosctl(~w(server status), opts)
      assert stderr =~ "no longer names the modules this server was made from"
      assert kept(home) == "0.5.0"
    end

    test "refuse another --version than up kept", %{
      github: github,
      opts: opts,
      home: home,
      tmp_dir: dir
    } do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [
        release("0.6.0", modules(dir)),
        release("0.5.0", modules(dir))
      ])

      {0, _stdout, ""} = ehosctl(~w(server up --provider oci --version 0.5.0), opts)
      made(home, "trial")

      {2, "", stderr} = ehosctl(~w(server status --version 0.6.0), opts)
      assert stderr =~ "made from EHOS 0.5.0's modules"
      assert stderr =~ "`ehosctl server up --installation trial --version 0.6.0`"
    end

    test "take the newest release for a server made with Mix, and keep it", %{
      github: github,
      opts: opts,
      home: home,
      tmp_dir: dir
    } do
      made(home, "trial")
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [release("0.5.0", modules(dir))])

      {0, "status done\n", ""} = ehosctl(~w(server status), opts)
      assert_received {:platform, :status, status}
      assert %EhosPlatform.Source{} = status[:source]
      assert Ehosctl.ServerRelease.kept_version(Path.join([home, "trial", "release"])) == "0.5.0"
    end

    test "need no release to close a tunnel", %{github: github, opts: opts, home: home} do
      made(home, "trial")
      FakeHTTP.down(github)

      {0, "close_tunnel done\n", ""} = ehosctl(~w(server tunnel --close), opts)
      assert_received {:platform, :close_tunnel, close}
      assert close[:source] == nil
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

      {0, "status done\n", ""} = ehosctl(~w(server status), opts)
      assert_received {:platform, :status, status}
      assert status[:source] == nil and status[:passphrase] == nil
      refute File.exists?(Path.join([home, "trial", "release"]))
    end

    test "down says what is lost, and removes the server once the installation's name is typed",
         %{github: github, opts: opts, home: home, tmp_dir: dir} do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [release("0.5.0", modules(dir, "aws"))])
      made(home, "acme")

      File.write!(
        Path.join([home, "acme", "installation.json"]),
        ~s({"provider": "aws", "region": "eu-central-1"})
      )

      current!(opts, "acme")
      mock_answer("acme\n")

      {0, "down done\n", ""} = ehosctl(~w(server down), opts)
      assert_received {:asked, question}
      assert question =~ "the installation acme on AWS in eu-central-1, for good"
      assert question =~ "the server ehos-acme and its disk, with EHOS's database and every"
      assert question =~ "its network"
      assert question =~ "goes back to AWS and may be given to anyone"
      assert question =~ "a mail relay's rule"
      assert question =~ "EHOS makes no backups yet, so nothing removed can be brought back."
      assert question =~ "The installation acme serves https://ehos.example.org."

      assert String.ends_with?(
               question,
               "Type the installation's name, acme, to remove its server: "
             )

      assert_received {:platform, :down, _opts}
    end

    # #430: a `y` out of habit, a wrong installation's name, or no answer, as a script's stdin
    # gives, removes nothing, downloads nothing, and fails so a script sees it.
    test "down removes nothing unless the installation's exact name is typed", %{
      github: github,
      opts: opts,
      home: home
    } do
      made(home, "acme")
      FakeHTTP.down(github)

      for answer <- ["y\n", "yes\n", "Acme\n", "trial\n", "acm\n", "\n", nil] do
        mock_answer(answer)
        {1, "", stderr} = ehosctl(~w(server down --installation acme), opts)

        assert_received {:asked, question}
        assert question =~ "the installation acme on Oracle Cloud, for good"
        refute question =~ "serves"
        assert stderr =~ "Nothing removed: the installation's name, acme, was not typed."
        assert stderr =~ "`ehosctl server down --installation acme`"
      end

      refute_received {:platform, :down, _opts}
      refute File.exists?(Path.join([home, "acme", "release"]))
    end

    test "down takes --yes only with --installation on the command line, and then asks nothing",
         %{github: github, opts: opts, home: home, tmp_dir: dir} do
      made(home, "acme")
      expect(Ehosctl.TerminalMock, :gets, 0, fn _question -> nil end)

      # Neither the current installation nor EHOSCTL_INSTALLATION names it for --yes.
      current!(opts, "acme")
      {2, "", stderr} = ehosctl(~w(server down --yes), opts)

      assert stderr =~ "--yes is taken only with --installation naming, on the command line"
      assert stderr =~ "(acme here)"
      refute stderr =~ "--installation acme"

      stub_env(%{"EHOSCTL_INSTALLATION" => "acme"})
      {2, "", _stderr} = ehosctl(~w(server down --yes), opts)
      refute_received {:platform, :down, _opts}

      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [release("0.5.0", modules(dir))])
      stub_env(%{})
      {0, "down done\n", ""} = ehosctl(~w(server down --installation acme --yes), opts)
      assert_received {:platform, :down, down}
      assert down[:name] == "acme"
    end

    test "down refuses an installation that was never made, and asks nothing", %{opts: opts} do
      expect(Ehosctl.TerminalMock, :gets, 0, fn _question -> nil end)

      {1, "", stderr} = ehosctl(~w(server down --installation acme), opts)
      assert stderr =~ "No server is known under acme"
      refute_received {:platform, :down, _opts}
    end

    test "unpack the kept archive again only when modules/ is not known to be its", %{
      github: github,
      opts: opts,
      home: home,
      tmp_dir: dir
    } do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [release("0.5.0", modules(dir))])
      {0, _stdout, ""} = ehosctl(~w(server up --provider oci), opts)
      made(home, "trial")
      main_tf = Path.join([home, "trial", "release", "modules", "deploy/tofu/oci/main.tf"])

      File.write!(main_tf, "# changed\n")
      {0, _stdout, ""} = ehosctl(~w(server status), opts)
      assert File.read!(main_tf) == "# changed\n"

      File.rm!(Path.join([home, "trial", "release", "modules.sha256"]))
      {0, _stdout, ""} = ehosctl(~w(server status), opts)
      assert File.read!(main_tf) == "# oci\n"
    end

    test "finish a keep that was interrupted between its renames", %{
      github: github,
      opts: opts,
      home: home,
      tmp_dir: dir
    } do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [
        release("0.6.0", modules(dir)),
        release("0.5.0", modules(dir))
      ])

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

      {0, "status done\n", ""} = ehosctl(~w(server status), opts)
      assert kept(home) == "0.5.0"
      refute File.exists?(base <> ".previous") or File.exists?(base <> ".next")

      # Stopped with no new release beside it, the old one is put back.
      File.rename!(base, base <> ".previous")
      {0, "status done\n", ""} = ehosctl(~w(server status), opts)
      assert kept(home) == "0.5.0"
    end

    test "take the options that size a server on up alone", %{opts: opts} do
      {2, "", stderr} = ehosctl(~w(server status --ocpus 1), opts)
      assert stderr =~ "--ocpus"
    end

    test "say how to go on when config.json cannot be read", %{
      opts: opts,
      home: home,
      github: github,
      tmp_dir: dir
    } do
      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [release("0.6.0", modules(dir))])
      made(home, "trial")
      File.mkdir_p!(opts[:config_dir])
      File.write!(Path.join(opts[:config_dir], "config.json"), "{not json")

      {1, "", stderr} = ehosctl(~w(server status), opts)
      assert stderr =~ "or name the installation with --installation or EHOSCTL_INSTALLATION"
      {0, _stdout, ""} = ehosctl(~w(server status --installation trial), opts)
    end
  end

  test "says in its help that it is on the platform plane", %{opts: opts} do
    {0, help, ""} = ehosctl(~w(server --help), opts)
    assert help =~ "Plane: platform."
  end

  # ehos-tools#197: EHOS's release command, which an operator ran with a line of kubectl.
  describe "invite" do
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

    @link "https://ehos.192-0-2-7.sslip.io/people/log-in/" <> String.duplicate("aB3_-", 9)
    @invited_line "Invited ada@example.com. This link signs them in once, within 15 minutes:"

    setup %{opts: opts, home: home} do
      # An invitation is refused under an installation no server's state is kept under (#194).
      for name <- ~w(trial acme), do: made(home, name)

      Process.put(
        {Invite, :invite},
        {:ok, %{invited: @invited_line, link: @link, administrator: nil, interrupted: nil}}
      )

      # No passphrase and no release: the invitation needs neither.
      %{opts: opts |> Keyword.delete(:passphrase) |> Keyword.put(:install, Invite)}
    end

    test "refuses an installation no server's state is kept under, before inviting", %{opts: opts} do
      {2, "", stderr} = ehosctl(~w(server invite ada@example.com --installation ghost), opts)

      assert stderr =~ "No server is known under ghost"
      refute_received {:invite, _opts}
    end

    test "prints EHOS's line, the link on a line of its own, and that the link is a password", %{
      opts: opts,
      home: home
    } do
      {0, stdout, ""} = ehosctl(~w(server invite ada@example.com --installation acme), opts)

      assert stdout ==
               @invited_line <>
                 "\n\n    " <>
                 @link <>
                 "\n\nThe link is a password: whoever opens it is signed in as that person. " <>
                 "Give it to them alone, in a direct message to an account you know is theirs, " <>
                 "never in a channel, a ticket or a thread others read. It works once, until " <>
                 "it is used or its 15 minutes pass, and a new one does not end it. If anyone " <>
                 "else may have seen it, disable the person (`ehosctl people disable " <>
                 "ada@example.com --installation acme`), which ends every link they hold, then enable them and run this command again; the " <>
                 "platform's only administrator cannot be disabled, so they open it at once, " <>
                 "which uses it up.\n"

      assert_received {:invite, invited}
      assert invited[:email] == "ada@example.com"
      assert invited[:name] == "acme"
      assert invited[:home] == home
      assert invited[:server_command] == "ehosctl server"
      assert invited[:name_option] == "--installation"
      assert invited[:name_in_commands] == true
      assert invited[:runner] == Ehosctl.PlatformRunner
    end

    test "says when the person became the platform's administrator, and when kubectl failed " <>
           "after the link",
         %{opts: opts} do
      administrator = "Nobody was administrator yet: ada@example.com is ehos.administrator now."

      Process.put(
        {Invite, :invite},
        {:ok,
         %{
           invited: @invited_line,
           link: @link,
           administrator: administrator,
           interrupted: "kubectl failed after it."
         }}
      )

      {0, stdout, ""} = ehosctl(~w(server invite ada@example.com), opts)
      assert stdout =~ "#{administrator}\nkubectl failed after it.\nThe link is a password"
      assert stdout =~ "    #{@link}\n\n#{administrator}\n"
      assert_received {:invite, invited}
      assert invited[:name] == "trial"
    end

    test "refuses an address EHOS would refuse before anything runs", %{opts: opts} do
      for email <- ["ada@example.com,alan@example.com", "ada", "ada\e[2J@example.com"] do
        {2, "", stderr} = ehosctl(["server", "invite", email], opts)
        assert stderr =~ "is not an email address EHOS takes"
        refute stderr =~ "\e"
        refute_received {:invite, _opts}
      end
    end

    test "says why it could not invite, and exits 1", %{opts: opts} do
      Process.put(
        {Invite, :invite},
        {:error, "EHOS did not invite ada@example.com: (ArgumentError) no"}
      )

      {1, "", stderr} = ehosctl(~w(server invite ada@example.com), opts)
      assert stderr == "ehosctl: EHOS did not invite ada@example.com: (ArgumentError) no\n"
    end

    test "writes the address into what EHOS evaluates as a string, through the installation's " <>
           "kubeconfig",
         %{opts: opts, home: home} do
      File.mkdir_p!(Path.join(home, "acme"))
      File.write!(Path.join([home, "acme", "kubeconfig"]), "{}")

      Process.put(
        {Kubectl, :answer},
        {"#{@invited_line}\n#{@link}\n", 0}
      )

      opts = opts |> Keyword.delete(:install) |> Keyword.put(:runner, Kubectl)
      email = ~S|a")<>throw(:injected)<>("@example.com|

      {0, stdout, ""} = ehosctl(["server", "invite", email, "--installation", "acme"], opts)
      assert stdout =~ "\n    #{@link}\n"

      assert_received {:kubectl, args}

      assert Enum.take(args, 4) == [
               "--kubeconfig",
               Path.join([home, "acme", "kubeconfig"]),
               "--context",
               "ehos-acme"
             ]

      assert List.last(args) ==
               ~S|Ehos.Release.invite("a\")<>throw(:injected)<>(\"@example.com")|
    end

    test "is listed in the help, which says the link is a password", %{opts: opts} do
      {0, help, ""} = ehosctl(~w(server --help), opts)
      assert help =~ "invite"

      {0, help, ""} = ehosctl(~w(server invite --help), opts)
      assert help =~ "The link is a password."
      assert help =~ "--installation"
    end
  end
end
