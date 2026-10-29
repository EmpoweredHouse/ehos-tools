defmodule Ehosctl.DoctorTest do
  use Ehosctl.Case, async: true

  alias Ehosctl.Doctor

  @moduletag :tmp_dir

  @oci_config """
  [DEFAULT]
  user=ocid1.user.oc1..aaaa
  fingerprint=00:11
  key_file=~/.oci/key.pem
  tenancy=ocid1.tenancy.oc1..bbbb
  region=eu-frankfurt-1
  """

  # mise, ssh and every pinned tool are there, unless a test says otherwise.
  setup %{tmp_dir: tmp_dir} do
    mock_find_executable(%{"mise" => "/usr/local/bin/mise", "ssh" => "/usr/bin/ssh"})
    mock_mise_which(tmp_dir, [])
  end

  # The report in `home`, the home directory `Ehosctl.OS` gives.
  defp report(home) do
    stub_home(home)
    Doctor.report()
  end

  defp with_oci(home) do
    File.mkdir_p!(Path.join(home, ".oci"))
    File.write!(Path.join(home, ".oci/config"), @oci_config)
    home
  end

  test "is ready when every tool is installed at its pin, ssh is there and an account is seen",
       %{tmp_dir: home} do
    report = report(with_oci(home))

    assert report.ready

    assert Enum.map(report.tools, &{&1.tool, &1.version, &1.state}) ==
             [
               {"opentofu", "1.13.1", "installed"},
               {"helm", "4.3.0", "installed"},
               {"kubectl", "1.37.1", "installed"}
             ]

    assert %{provider: "oci", state: "found", detail: detail} = hd(report.accounts)
    assert detail =~ "eu-frankfurt-1"
  end

  test "names the command that installs a tool that is missing, and is not ready",
       %{tmp_dir: home} do
    mock_mise_which(home, ["helm"])
    report = report(with_oci(home))

    refute report.ready

    assert %{state: "missing", install: "mise install helm@4.3.0"} =
             Enum.find(report.tools, &(&1.tool == "helm"))
  end

  test "without mise, every tool is missing and the way to install mise is named",
       %{tmp_dir: home} do
    mock_find_executable(%{"ssh" => "/usr/bin/ssh"})
    report = report(with_oci(home))

    refute report.ready
    assert Enum.all?(report.tools, &(&1.state == "missing" and &1.install =~ "mise.jdx.dev"))
  end

  test "is not ready without ssh, or without any cloud account", %{tmp_dir: home} do
    mock_find_executable(%{"mise" => "/usr/local/bin/mise"})
    refute report(with_oci(home)).ready

    mock_find_executable(%{"mise" => "/usr/local/bin/mise", "ssh" => "/usr/bin/ssh"})

    empty = Path.join(home, "empty")
    File.mkdir_p!(empty)
    report = report(empty)
    refute report.ready

    assert Enum.map(report.accounts, &{&1.provider, &1.state}) ==
             [{"oci", "none"}, {"aws", "none"}, {"gcp", "none"}, {"ovh", "none"}]
  end

  # eh-os D-83: `server up` takes keys in the environment out of OpenTofu's, and uses a profile.
  test "sees an AWS profile in ~/.aws, and not keys in the environment alone", %{tmp_dir: home} do
    stub_env(%{"AWS_ACCESS_KEY_ID" => "AKIASECRET"})
    assert %{state: "none"} = aws(report(home))

    File.mkdir_p!(Path.join(home, ".aws"))
    File.write!(Path.join(home, ".aws/config"), "[profile prod]\nregion = eu-central-1\n")

    stub_env(%{"AWS_PROFILE" => "prod"})
    assert %{state: "found", detail: detail} = aws(report(home))
    assert detail =~ "prod"

    stub_env(%{})
    assert %{state: "none"} = aws(report(home))
  end

  test "reads a configuration that is a link, as dotfile managers make them", %{tmp_dir: home} do
    dotfiles = Path.join(home, "dotfiles")
    File.mkdir_p!(dotfiles)
    File.write!(Path.join(dotfiles, "oci-config"), @oci_config)
    File.write!(Path.join(dotfiles, "aws-config"), "[profile   prod]\nregion = eu-central-1\n")
    File.mkdir_p!(Path.join(home, ".oci"))
    File.mkdir_p!(Path.join(home, ".aws"))
    File.ln_s!(Path.join(dotfiles, "oci-config"), Path.join(home, ".oci/config"))
    File.ln_s!(Path.join(dotfiles, "aws-config"), Path.join(home, ".aws/config"))

    stub_env(%{"AWS_PROFILE" => "prod"})
    report = report(home)
    assert %{provider: "oci", state: "found"} = hd(report.accounts)
    assert %{state: "found"} = aws(report)
  end

  test "a FIFO or a device where ~/.oci/config should be is not read", %{tmp_dir: home} do
    File.mkdir_p!(Path.join(home, ".oci"))
    {_, 0} = System.cmd("mkfifo", [Path.join(home, ".oci/config")])

    stub_home(home)
    task = Task.async(fn -> Doctor.report() end)
    assert %{accounts: [%{provider: "oci", state: "none"} | _]} = Task.await(task, 5_000)
  end

  test "sees AWS and GCP accounts, and prints no secret", %{tmp_dir: home} do
    File.mkdir_p!(Path.join(home, ".aws"))

    File.write!(
      Path.join(home, ".aws/credentials"),
      "[default]\naws_access_key_id = AKIASECRET\n"
    )

    credentials = Path.join(home, "gcp.json")
    File.write!(credentials, ~s({"private_key": "SECRET-GCP"}))

    env = %{
      "AWS_ACCESS_KEY_ID" => "AKIASECRET",
      "GOOGLE_APPLICATION_CREDENTIALS" => credentials,
      "GOOGLE_CLOUD_PROJECT" => "acme-ehos",
      "GHCR_TOKEN" => "ghp_SECRET"
    }

    stub_env(env)
    report = report(home)

    assert report.ready
    assert %{state: "found"} = aws(report)
    assert %{state: "found", detail: detail} = Enum.find(report.accounts, &(&1.provider == "gcp"))
    assert detail =~ "acme-ehos"
    assert report.ghcr_token == "set"

    printed = inspect(report)
    refute printed =~ "AKIASECRET"
    refute printed =~ "SECRET-GCP"
    refute printed =~ "ghp_SECRET"
  end

  test "a GCP credential without a project is incomplete, and not an account to use",
       %{tmp_dir: home} do
    File.mkdir_p!(Path.join(home, ".config/gcloud"))
    File.write!(Path.join(home, ".config/gcloud/application_default_credentials.json"), "{}")

    report = report(home)
    assert %{state: "incomplete"} = Enum.find(report.accounts, &(&1.provider == "gcp"))
    refute report.ready
  end

  test "exits 0 with the report when ready, and 1 after printing it when not", %{tmp_dir: home} do
    stub_home(with_oci(home))
    assert {:ok, %{text: text}} = Doctor.call([], %{flags: %{json: false}}, [])
    assert text =~ "Ready for `ehosctl server up`."

    mock_find_executable(%{"ssh" => "/usr/bin/ssh"})

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert 1 == Doctor.call([], %{flags: %{json: false}}, [])
      end)

    assert output =~ "Not ready"
  end

  # eh-os D-127: OVHcloud's account is an entry of OpenStack's clouds.yaml, named by OS_CLOUD or
  # `ovh`; only its presence is read, never a secret in it.
  test "sees an OVHcloud entry in clouds.yaml, and never prints what it holds", %{tmp_dir: home} do
    assert %{state: "none"} = ovh(report(home))

    File.mkdir_p!(Path.join(home, ".config/openstack"))

    File.write!(Path.join(home, ".config/openstack/clouds.yaml"), """
    clouds:
      ovh:
        auth: {password: s3cret}
      acme: {}
    """)

    report = report(home)
    assert %{state: "found", detail: detail} = ovh(report)
    assert detail =~ "entry ovh in"
    assert report.ready
    refute inspect(report) =~ "s3cret"

    stub_env(%{"OS_CLOUD" => "other"})
    assert %{state: "none", detail: detail} = ovh(report(home))
    assert detail =~ ~s(no entry "other")

    # A file that is not one says so, rather than that the entry is missing.
    stub_env(%{"OS_CLIENT_CONFIG_FILE" => Path.join(home, "missing.yaml")})
    assert %{state: "none", detail: detail} = ovh(report(home))
    assert detail =~ "cannot be read as OpenStack's clouds.yaml"
  end

  defp aws(report), do: Enum.find(report.accounts, &(&1.provider == "aws"))

  # The programs on the `PATH`, a map of names to paths.
  defp mock_find_executable(found),
    do: stub(Ehosctl.OSMock, :find_executable, &Map.get(found, &1))

  # `mise which` finds every pinned tool but `missing`, each a file in `dir`, as mise prints it.
  defp mock_mise_which(dir, missing) do
    stub(Ehosctl.RunnerMock, :run, fn "/usr/local/bin/mise", ["which", program | _], _opts ->
      if program in missing do
        {"mise ERROR #{program} is not installed\n", 1}
      else
        path = Path.join(dir, program)
        File.write!(path, "")
        {path <> "\n", 0}
      end
    end)

    :ok
  end

  defp ovh(report), do: Enum.find(report.accounts, &(&1.provider == "ovh"))
end
