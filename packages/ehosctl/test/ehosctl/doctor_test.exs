defmodule Ehosctl.DoctorTest do
  use ExUnit.Case, async: true

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

  defp opts(home, overrides \\ []) do
    Keyword.merge(
      [
        home: home,
        mise: "/usr/local/bin/mise",
        resolve: fn program, "/usr/local/bin/mise" -> {:ok, "/mise/installs/#{program}"} end,
        find_executable: fn "ssh" -> "/usr/bin/ssh" end,
        env: fn _name -> nil end
      ],
      overrides
    )
  end

  defp with_oci(home) do
    File.mkdir_p!(Path.join(home, ".oci"))
    File.write!(Path.join(home, ".oci/config"), @oci_config)
    home
  end

  test "is ready when every tool is installed at its pin, ssh is there and an account is seen",
       %{tmp_dir: home} do
    report = Doctor.report(opts(with_oci(home)))

    assert report.ready

    assert Enum.map(report.tools, &{&1.tool, &1.version, &1.state}) ==
             [
               {"opentofu", "1.13.1", "installed"},
               {"helm", "4.3.0", "installed"},
               {"kubectl", "1.36.4", "installed"}
             ]

    assert %{provider: "oci", state: "found", detail: detail} = hd(report.accounts)
    assert detail =~ "eu-frankfurt-1"
  end

  test "names the command that installs a tool that is missing, and is not ready",
       %{tmp_dir: home} do
    resolve = fn
      "helm", _mise -> {:error, :not_found}
      program, _mise -> {:ok, "/mise/installs/#{program}"}
    end

    report = Doctor.report(opts(with_oci(home), resolve: resolve))

    refute report.ready

    assert %{state: "missing", install: "mise install helm@4.3.0"} =
             Enum.find(report.tools, &(&1.tool == "helm"))
  end

  test "without mise, every tool is missing and the way to install mise is named",
       %{tmp_dir: home} do
    report = Doctor.report(opts(with_oci(home), mise: false))

    refute report.ready
    assert Enum.all?(report.tools, &(&1.state == "missing" and &1.install =~ "mise.jdx.dev"))
  end

  test "is not ready without ssh, or without any cloud account", %{tmp_dir: home} do
    refute Doctor.report(opts(with_oci(home), find_executable: fn "ssh" -> nil end)).ready

    empty = Path.join(home, "empty")
    File.mkdir_p!(empty)
    report = Doctor.report(opts(empty))
    refute report.ready

    assert Enum.map(report.accounts, &{&1.provider, &1.state}) ==
             [{"oci", "none"}, {"aws", "none"}, {"gcp", "none"}]
  end

  # eh-os D-83: `server up` takes keys in the environment out of OpenTofu's, and uses a profile.
  test "sees an AWS profile in ~/.aws, and not keys in the environment alone", %{tmp_dir: home} do
    keys = fn
      "AWS_ACCESS_KEY_ID" -> "AKIASECRET"
      _name -> nil
    end

    assert %{state: "none"} = aws(Doctor.report(opts(home, env: keys)))

    File.mkdir_p!(Path.join(home, ".aws"))
    File.write!(Path.join(home, ".aws/config"), "[profile prod]\nregion = eu-central-1\n")

    profile = fn
      "AWS_PROFILE" -> "prod"
      _name -> nil
    end

    assert %{state: "found", detail: detail} = aws(Doctor.report(opts(home, env: profile)))
    assert detail =~ "prod"
    assert %{state: "none"} = aws(Doctor.report(opts(home)))
  end

  test "a FIFO or a device where ~/.oci/config should be is not read", %{tmp_dir: home} do
    File.mkdir_p!(Path.join(home, ".oci"))
    {_, 0} = System.cmd("mkfifo", [Path.join(home, ".oci/config")])

    task = Task.async(fn -> Doctor.report(opts(home)) end)
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

    env = fn
      "AWS_ACCESS_KEY_ID" -> "AKIASECRET"
      "GOOGLE_APPLICATION_CREDENTIALS" -> credentials
      "GOOGLE_CLOUD_PROJECT" -> "acme-ehos"
      "GHCR_TOKEN" -> "ghp_SECRET"
      _name -> nil
    end

    report = Doctor.report(opts(home, env: env))

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

    report = Doctor.report(opts(home))
    assert %{state: "incomplete"} = Enum.find(report.accounts, &(&1.provider == "gcp"))
    refute report.ready
  end

  test "exits 0 with the report when ready, and 1 after printing it when not", %{tmp_dir: home} do
    ready = opts(with_oci(home))
    assert {:ok, %{text: text}} = Doctor.call([], %{flags: %{json: false}}, ready)
    assert text =~ "Ready for `ehosctl server up`."

    not_ready = Keyword.put(ready, :mise, false)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert 1 == Doctor.call([], %{flags: %{json: false}}, not_ready)
      end)

    assert output =~ "Not ready"
  end

  defp aws(report), do: Enum.find(report.accounts, &(&1.provider == "aws"))
end
