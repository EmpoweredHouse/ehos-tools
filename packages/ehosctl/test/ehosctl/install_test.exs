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
      Process.get({__MODULE__, :installed}, {:ok, :none})
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

  test "installs the version that runs again, and refuses another as an upgrade", %{opts: opts} do
    Process.put({Platform, :installed}, {:ok, %{"version" => "0.6.0"}})
    {0, _stdout, ""} = ehosctl(~w(install), opts)
    assert_received {:server, _server}

    Process.put({Platform, :installed}, {:ok, %{"version" => "0.5.0"}})
    {2, "", stderr} = ehosctl(~w(install), opts)
    assert stderr =~ "trial runs EHOS 0.5.0; moving it to 0.6.0 is an upgrade"
    refute_received {:server, _server}
  end

  test "refuses an installation whose version nothing recorded", %{opts: opts} do
    Process.put({Platform, :installed}, {:ok, :unknown})
    {2, "", stderr} = ehosctl(~w(install), opts)
    assert stderr =~ "recorded nothing of its version, as `mix ehos.install` installs it"
    refute_received {:server, _server}
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

    {0, _stdout, ""} = ehosctl(~w(install --installation acme), opts)
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
  end

  test "says in its help that it is on the platform plane", %{opts: opts} do
    {0, help, ""} = ehosctl(~w(install --help), opts)
    assert help =~ "Plane: platform."
  end
end
