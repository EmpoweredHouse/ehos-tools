defmodule Ehosctl.ServerTest do
  # Not async: capture_io(:stderr) captures stderr for every process.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Ehosctl.Config
  alias Ehosctl.FakeGitHub

  @moduletag :tmp_dir

  # In place of `EhosPlatform.Server`: says what it was asked, with which options, and answers.
  defmodule Platform do
    @moduledoc false

    for fun <- [:up, :down, :status, :tunnel, :close_tunnel] do
      def unquote(fun)(opts) do
        send(self(), {:platform, unquote(fun), opts})
        {:ok, "#{unquote(fun)} done"}
      end
    end

    defdelegate made?(opts), to: EhosPlatform.Server
  end

  @chart "oci://ghcr.io/empoweredhouse/charts/ehos@sha256:" <> String.duplicate("a", 64)

  setup %{tmp_dir: dir} do
    {github, github_opts} = FakeGitHub.start()

    opts =
      [
        server: Platform,
        home: Path.join(dir, "ehos"),
        config_dir: Path.join(dir, "config"),
        env: %{},
        passphrase: String.duplicate("p", 16)
      ] ++ github_opts

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

  defp made(home, name) do
    File.mkdir_p!(Path.join(home, name))
    File.write!(Path.join([home, name, "server.tfvars.json"]), "{}")
  end

  describe "the installation" do
    test "is --installation, else EHOSCTL_INSTALLATION, else the current one, else trial", %{
      opts: opts
    } do
      assert Ehosctl.Server.installation(nil, opts) == {:ok, "trial"}

      :ok =
        Config.write(
          %Config{current: "acme", installations: %{"acme" => %{"url" => "https://ehos.acme"}}},
          opts[:config_dir]
        )

      assert Ehosctl.Server.installation(nil, opts) == {:ok, "acme"}

      opts = Keyword.put(opts, :env, %{"EHOSCTL_INSTALLATION" => "staging"})
      assert Ehosctl.Server.installation(nil, opts) == {:ok, "staging"}
      assert Ehosctl.Server.installation("check", opts) == {:ok, "check"}
    end

    test "is refused before anything runs when the OpenTofu module would refuse it", %{
      opts: opts
    } do
      {2, "", stderr} =
        ehosctl(["server", "status", "--installation", "a-name-longer-than-sixteen"], opts)

      assert stderr =~ "cannot name a server: The installation's name is 2 to 16"
      refute_received {:platform, _fun, _opts}
    end
  end

  describe "up" do
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

      argv = ~w(server up --ssh-from 192.0.2.1 --ssh-from 198.51.100.0/24 --ocpus 1 --replace)
      {0, "up done\n", ""} = ehosctl(argv, opts)

      assert_received {:platform, :up, up}
      assert up[:name] == "trial"
      assert up[:home] == Path.join(dir, "ehos")
      assert up[:ssh_from] == ["192.0.2.1", "198.51.100.0/24"]
      assert up[:ocpus] == 1 and up[:replace] == true
      assert up[:runner] == Ehosctl.PlatformRunner
      assert up[:command] == "ehosctl server" and up[:name_option] == "--installation"

      assert %EhosPlatform.Source{chart: {:oci, @chart}, modules: modules} = up[:source]
      assert modules == Path.join([home, "trial", "release", "modules"])
      assert File.read!(Path.join(modules, "deploy/tofu/oci/main.tf")) == "# oci\n"
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

      {0, _stdout, ""} = ehosctl(~w(server up --version 0.5.0), opts)
      assert Ehosctl.ServerRelease.kept_version(Path.join([home, "trial", "release"])) == "0.5.0"

      {2, "", stderr} = ehosctl(~w(server up --version 0.4.0), opts)
      assert stderr =~ "EHOS has no release 0.4.0"
    end

    test "refuses a modules' archive whose SHA-256 is not the one release.json names, and makes nothing",
         %{github: github, opts: opts, tmp_dir: dir} do
      {archive, _sha256} = modules(dir)

      FakeGitHub.releases(github, "EmpoweredHouse/eh-os", [
        release("0.6.0", {archive, String.duplicate("0", 64)})
      ])

      {1, "", stderr} = ehosctl(~w(server up), opts)
      assert stderr =~ "SHA-256"
      refute_received {:platform, :up, _opts}
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

      {1, "", stderr} = ehosctl(~w(server up), opts)
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
      {0, _stdout, ""} = ehosctl(~w(server up), opts)
      made(home, "trial")

      # A newer release is out, and GitHub no longer answers: neither changes the modules.
      Bypass.down(github)

      {0, "status done\n", ""} = ehosctl(~w(server status), opts)
      assert_received {:platform, :status, status}
      assert status[:source].modules == Path.join([home, "trial", "release", "modules"])

      {0, "tunnel done\n", ""} = ehosctl(~w(server tunnel --port 16500), opts)
      assert_received {:platform, :tunnel, tunnel}
      assert tunnel[:port] == 16_500
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

      {0, _stdout, ""} = ehosctl(~w(server up --version 0.5.0), opts)
      made(home, "trial")

      {2, "", stderr} = ehosctl(~w(server status --version 0.6.0), opts)
      assert stderr =~ "made from EHOS 0.5.0's modules"
      assert stderr =~ "ehosctl server up --version 0.6.0"
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

    test "need no release for a server not made yet, nor to close a tunnel", %{
      github: github,
      opts: opts
    } do
      Bypass.down(github)

      {0, "status done\n", ""} = ehosctl(~w(server status --installation acme), opts)
      assert_received {:platform, :status, status}
      assert status[:name] == "acme" and status[:source] == nil

      {0, "close_tunnel done\n", ""} = ehosctl(~w(server tunnel --close), opts)
      assert_received {:platform, :close_tunnel, _opts}
    end

    test "down names the installation and asks first; no is nothing removed", %{opts: opts} do
      opts =
        Keyword.put(opts, :confirm, fn question ->
          send(self(), {:asked, question})
          false
        end)

      {0, "Nothing removed.\n", ""} = ehosctl(~w(server down --installation acme), opts)
      assert_received {:asked, question}
      assert question =~ "the installation acme, ehos-acme"
      refute_received {:platform, :down, _opts}

      {0, "down done\n", ""} = ehosctl(~w(server down --installation acme --yes), opts)
      assert_received {:platform, :down, _opts}
    end
  end

  test "says in its help that it is on the platform plane", %{opts: opts} do
    {0, help, ""} = ehosctl(~w(server --help), opts)
    assert help =~ "Plane: platform."
  end
end
