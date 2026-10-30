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

  # Each provider's account as a home without one reports it, and OCI's as `@oci_config` gives it.
  @oci_found %{
    provider: "oci",
    state: "found",
    detail: "profile DEFAULT in ~/.oci/config, region eu-frankfurt-1"
  }
  @aws_none %{provider: "aws", state: "none", detail: "no profile default in ~/.aws"}
  @gcp_none %{provider: "gcp", state: "none", detail: "no application credentials"}
  @ovh_none %{
    provider: "ovh",
    state: "none",
    detail: "no clouds.yaml in ~/.config/openstack or OS_CLIENT_CONFIG_FILE"
  }

  # mise, ssh, every pinned tool and a GitHub token are there, unless a test says otherwise.
  setup %{tmp_dir: tmp_dir} do
    mock_find_executable(%{"mise" => "/usr/local/bin/mise", "ssh" => "/usr/bin/ssh"})
    mock_run(tmp_dir, [])
    stub_env(%{"MISE_GITHUB_TOKEN" => "ghp_SECRET"})
  end

  test "is ready when every tool is installed at its pin, ssh is there and an account is seen",
       %{tmp_dir: home} do
    assert report(with_oci(home)) == %{
             tools: installed_tools(),
             ssh: "found",
             accounts: [@oci_found, @aws_none, @gcp_none, @ovh_none],
             gcp_policies: [],
             github_token: "set in MISE_GITHUB_TOKEN",
             ghcr_token: "not set",
             ready: true
           }
  end

  # eh-os D-83: `server up` takes keys in the environment out of OpenTofu's, and uses a profile.
  test "sees an AWS profile in ~/.aws, and not keys in the environment alone", %{tmp_dir: home} do
    stub_env(%{"AWS_ACCESS_KEY_ID" => "AKIASECRET"})
    assert report(home).accounts == [oci_none(home), @aws_none, @gcp_none, @ovh_none]

    File.mkdir_p!(Path.join(home, ".aws"))
    File.write!(Path.join(home, ".aws/config"), "[profile prod]\nregion = eu-central-1\n")

    stub_env(%{"AWS_PROFILE" => "prod"})

    assert report(home).accounts == [
             oci_none(home),
             %{provider: "aws", state: "found", detail: "profile prod in ~/.aws"},
             @gcp_none,
             @ovh_none
           ]

    stub_env(%{})
    assert report(home).accounts == [oci_none(home), @aws_none, @gcp_none, @ovh_none]
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

    assert report(home).accounts == [
             @oci_found,
             %{provider: "aws", state: "found", detail: "profile prod in ~/.aws"},
             @gcp_none,
             @ovh_none
           ]
  end

  test "sees AWS and GCP accounts, and prints no secret", %{tmp_dir: home} do
    File.mkdir_p!(Path.join(home, ".aws"))

    File.write!(
      Path.join(home, ".aws/credentials"),
      "[default]\naws_access_key_id = AKIASECRET\n"
    )

    credentials = Path.join(home, "gcp.json")
    File.write!(credentials, ~s({"private_key": "SECRET-GCP"}))

    stub_env(%{
      "AWS_ACCESS_KEY_ID" => "AKIASECRET",
      "GOOGLE_APPLICATION_CREDENTIALS" => credentials,
      "GOOGLE_CLOUD_PROJECT" => "acme-ehos",
      "GHCR_TOKEN" => "ghp_SECRET",
      "GITHUB_TOKEN" => "ghp_SECRET"
    })

    assert report(home) == %{
             tools: installed_tools(),
             ssh: "found",
             accounts: [
               oci_none(home),
               %{provider: "aws", state: "found", detail: "profile default in ~/.aws"},
               %{
                 provider: "gcp",
                 state: "found",
                 detail:
                   "GOOGLE_APPLICATION_CREDENTIALS, project acme-ehos; gcloud is not installed, " <>
                     "so they are not checked"
               },
               @ovh_none
             ],
             gcp_policies: [
               policy(
                 "compute.requireOsLogin",
                 "unknown",
                 "not checked: gcloud is not installed"
               ),
               policy(
                 "compute.vmExternalIpAccess",
                 "unknown",
                 "not checked: gcloud is not installed"
               )
             ],
             github_token: "set in GITHUB_TOKEN",
             ghcr_token: "set",
             ready: true
           }
  end

  # eh-os D-127: OVHcloud's account is an entry of OpenStack's clouds.yaml, named by OS_CLOUD or
  # `ovh`; only its presence is read, never a secret in it.
  test "sees an OVHcloud entry in clouds.yaml, and never prints what it holds", %{tmp_dir: home} do
    assert ovh(report(home)) == @ovh_none

    File.mkdir_p!(Path.join(home, ".config/openstack"))

    File.write!(Path.join(home, ".config/openstack/clouds.yaml"), """
    clouds:
      ovh:
        auth: {password: s3cret}
      acme: {}
    """)

    clouds_yaml = Path.join(home, ".config/openstack/clouds.yaml")

    assert report(home) == %{
             tools: installed_tools(),
             ssh: "found",
             accounts: [
               oci_none(home),
               @aws_none,
               @gcp_none,
               %{provider: "ovh", state: "found", detail: "entry ovh in #{clouds_yaml}"}
             ],
             gcp_policies: [],
             github_token: "set in MISE_GITHUB_TOKEN",
             ghcr_token: "not set",
             ready: true
           }

    stub_env(%{"OS_CLOUD" => "other"})

    assert ovh(report(home)) == %{
             provider: "ovh",
             state: "none",
             detail:
               ~s(#{clouds_yaml} has no entry "other" under `clouds`; name the entry with ) <>
                 "--os-cloud"
           }

    # A file that is not one says so, rather than that the entry is missing.
    stub_env(%{"OS_CLIENT_CONFIG_FILE" => Path.join(home, "missing.yaml")})

    assert ovh(report(home)) == %{
             provider: "ovh",
             state: "none",
             detail:
               "#{home}/missing.yaml cannot be read as OpenStack's clouds.yaml. Download the " <>
                 "clouds.yaml of an OpenStack user of your OVHcloud project (D-127)"
           }
  end

  test "exits 0 with the report when ready, and 1 after printing it when not", %{tmp_dir: home} do
    stub_home(with_oci(home))

    assert Doctor.call([], %{flags: %{json: false}, options: %{}}, []) ==
             {:ok,
              %{
                text: """
                Tools, at the versions EHOS is tested with:
                  ok opentofu 1.13.1
                  ok helm 4.3.0
                  ok kubectl 1.37.1
                  ok ssh: found

                Cloud accounts:
                  ok Oracle Cloud: profile DEFAULT in ~/.oci/config, region eu-frankfurt-1
                  -- AWS: no profile default in ~/.aws
                  -- GCP: no application credentials
                  -- OVHcloud: no clouds.yaml in ~/.config/openstack or OS_CLIENT_CONFIG_FILE

                GitHub token, for EHOS's releases: set in MISE_GITHUB_TOKEN
                GHCR_TOKEN, for `ehosctl install`: not set

                Ready for `ehosctl server up`.\
                """,
                json: %{
                  tools: installed_tools(),
                  ssh: "found",
                  accounts: [@oci_found, @aws_none, @gcp_none, @ovh_none],
                  gcp_policies: [],
                  github_token: "set in MISE_GITHUB_TOKEN",
                  ghcr_token: "not set",
                  ready: true
                }
              }}

    mock_find_executable(%{"ssh" => "/usr/bin/ssh"})

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert Doctor.call([], %{flags: %{json: false}, options: %{}}, []) == 1
      end)

    assert output == """
           Tools, at the versions EHOS is tested with:
             -- opentofu 1.13.1: missing, install mise: https://mise.jdx.dev/installing-mise.html
             -- helm 4.3.0: missing, install mise: https://mise.jdx.dev/installing-mise.html
             -- kubectl 1.37.1: missing, install mise: https://mise.jdx.dev/installing-mise.html
             ok ssh: found

           Cloud accounts:
             ok Oracle Cloud: profile DEFAULT in ~/.oci/config, region eu-frankfurt-1
             -- AWS: no profile default in ~/.aws
             -- GCP: no application credentials
             -- OVHcloud: no clouds.yaml in ~/.config/openstack or OS_CLIENT_CONFIG_FILE

           GitHub token, for EHOS's releases: set in MISE_GITHUB_TOKEN
           GHCR_TOKEN, for `ehosctl install`: not set

           Not ready: install or set what is missing, then run `ehosctl doctor` again.
           """
  end

  test "names the command that installs a tool that is missing, and is not ready",
       %{tmp_dir: home} do
    mock_run(home, ["helm"])

    assert report(with_oci(home)) == %{
             tools: [
               tool("opentofu", "installed"),
               tool("helm", "missing", "mise install helm@4.3.0"),
               tool("kubectl", "installed")
             ],
             ssh: "found",
             accounts: [@oci_found, @aws_none, @gcp_none, @ovh_none],
             gcp_policies: [],
             github_token: "set in MISE_GITHUB_TOKEN",
             ghcr_token: "not set",
             ready: false
           }
  end

  test "without mise, every tool is missing and the way to install mise is named",
       %{tmp_dir: home} do
    mock_find_executable(%{"ssh" => "/usr/bin/ssh"})
    install_mise = "install mise: https://mise.jdx.dev/installing-mise.html"

    assert report(with_oci(home)) == %{
             tools: [
               tool("opentofu", "missing", install_mise),
               tool("helm", "missing", install_mise),
               tool("kubectl", "missing", install_mise)
             ],
             ssh: "found",
             accounts: [@oci_found, @aws_none, @gcp_none, @ovh_none],
             gcp_policies: [],
             github_token: "set in MISE_GITHUB_TOKEN",
             ghcr_token: "not set",
             ready: false
           }
  end

  test "is not ready without ssh, or without any cloud account", %{tmp_dir: home} do
    mock_find_executable(%{"mise" => "/usr/local/bin/mise"})

    assert report(with_oci(home)) == %{
             tools: installed_tools(),
             ssh: "missing",
             accounts: [@oci_found, @aws_none, @gcp_none, @ovh_none],
             gcp_policies: [],
             github_token: "set in MISE_GITHUB_TOKEN",
             ghcr_token: "not set",
             ready: false
           }

    mock_find_executable(%{"mise" => "/usr/local/bin/mise", "ssh" => "/usr/bin/ssh"})

    empty = Path.join(home, "empty")
    File.mkdir_p!(empty)

    assert report(empty) == %{
             tools: installed_tools(),
             ssh: "found",
             accounts: [oci_none(empty), @aws_none, @gcp_none, @ovh_none],
             gcp_policies: [],
             github_token: "set in MISE_GITHUB_TOKEN",
             ghcr_token: "not set",
             ready: false
           }
  end

  test "a FIFO or a device where ~/.oci/config should be is not read", %{tmp_dir: home} do
    File.mkdir_p!(Path.join(home, ".oci"))
    {_, 0} = System.cmd("mkfifo", [Path.join(home, ".oci/config")])

    stub_home(home)
    task = Task.async(fn -> Doctor.report() end)

    assert Task.await(task, 5_000).accounts == [
             %{
               provider: "oci",
               state: "none",
               detail: "#{home}/.oci/config is not a configuration file"
             },
             @aws_none,
             @gcp_none,
             @ovh_none
           ]
  end

  test "a GCP credential without a project is incomplete, and not an account to use",
       %{tmp_dir: home} do
    File.mkdir_p!(Path.join(home, ".config/gcloud"))
    File.write!(Path.join(home, ".config/gcloud/application_default_credentials.json"), "{}")

    assert report(home) == %{
             tools: installed_tools(),
             ssh: "found",
             accounts: [
               oci_none(home),
               @aws_none,
               %{
                 provider: "gcp",
                 state: "incomplete",
                 detail:
                   "gcloud's application default credentials, but no --gcp-project or " <>
                     "GOOGLE_CLOUD_PROJECT"
               },
               @ovh_none
             ],
             gcp_policies: [],
             github_token: "set in MISE_GITHUB_TOKEN",
             ghcr_token: "not set",
             ready: false
           }
  end

  # `server up` reads EHOS's releases from GitHub, whose repositories are private
  # (ehos-tools#657).
  test "is not ready without a GitHub token for EHOS's releases, and names `gh auth token`",
       %{tmp_dir: home} do
    stub_env(%{})

    assert report(with_oci(home)) == %{
             tools: installed_tools(),
             ssh: "found",
             accounts: [@oci_found, @aws_none, @gcp_none, @ovh_none],
             gcp_policies: [],
             github_token: "not set",
             ghcr_token: "not set",
             ready: false
           }

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert Doctor.call([], %{flags: %{json: false}, options: %{}}, []) == 1
      end)

    assert ("GitHub token, for EHOS's releases: not set; set MISE_GITHUB_TOKEN or GITHUB_TOKEN, " <>
              "for example to `gh auth token`") in String.split(output, "\n")

    stub_env(%{"GITHUB_TOKEN" => "ghp_SECRET", "MISE_GITHUB_TOKEN" => ""})
    assert report(home).github_token == "set in GITHUB_TOKEN"
  end

  test "asks gcloud for an access token and reads the organisation policies, printing no token",
       %{tmp_dir: home} do
    stub_home(with_gcp(home))
    stub_env(%{"GITHUB_TOKEN" => "ghp_SECRET", "GOOGLE_CLOUD_PROJECT" => "acme-ehos"})

    mock_gcloud(home, fn
      ["auth", "application-default", "print-access-token"] -> {"ya29.SECRET\n", 0}
      ["org-policies", "describe", constraint | _args] -> {policy_json(constraint, []), 0}
    end)

    assert Doctor.call([], %{flags: %{json: false}, options: %{}}, []) ==
             {:ok,
              %{
                text: """
                Tools, at the versions EHOS is tested with:
                  ok opentofu 1.13.1
                  ok helm 4.3.0
                  ok kubectl 1.37.1
                  ok ssh: found

                Cloud accounts:
                  -- Oracle Cloud: no #{home}/.oci/config
                  -- AWS: no profile default in ~/.aws
                  ok GCP: gcloud's application default credentials, project acme-ehos
                  -- OVHcloud: no clouds.yaml in ~/.config/openstack or OS_CLIENT_CONFIG_FILE

                GCP organisation policies:
                  ok compute.requireOsLogin: not enforced
                  ok compute.vmExternalIpAccess: allows a public address

                GitHub token, for EHOS's releases: set in GITHUB_TOKEN
                GHCR_TOKEN, for `ehosctl install`: not set

                Ready for `ehosctl server up`.\
                """,
                json: %{
                  tools: installed_tools(),
                  ssh: "found",
                  accounts: [
                    oci_none(home),
                    @aws_none,
                    %{
                      provider: "gcp",
                      state: "found",
                      detail: "gcloud's application default credentials, project acme-ehos"
                    },
                    @ovh_none
                  ],
                  gcp_policies: [
                    policy("compute.requireOsLogin", "allows", "not enforced"),
                    policy("compute.vmExternalIpAccess", "allows", "allows a public address")
                  ],
                  github_token: "set in GITHUB_TOKEN",
                  ghcr_token: "not set",
                  ready: true
                }
              }}
  end

  # On 30 October 2026 gcloud's own sign-in had expired while the file was still there.
  test "credentials gcloud gets no access token with are refused, with the command that renews them",
       %{tmp_dir: home} do
    with_gcp(home)
    stub_env(%{"GITHUB_TOKEN" => "ghp_SECRET", "GOOGLE_CLOUD_PROJECT" => "acme-ehos"})

    mock_gcloud(home, fn ["auth", "application-default", "print-access-token"] ->
      {"ERROR: (gcloud.auth.application-default.print-access-token) Reauthentication failed.\n",
       1}
    end)

    assert report(home) == %{
             tools: installed_tools(),
             ssh: "found",
             accounts: [
               oci_none(home),
               @aws_none,
               %{
                 provider: "gcp",
                 state: "refused",
                 detail:
                   "gcloud's application default credentials give no access token; renew them " <>
                     "with `gcloud auth application-default login`"
               },
               @ovh_none
             ],
             gcp_policies: [],
             github_token: "set in GITHUB_TOKEN",
             ghcr_token: "not set",
             ready: false
           }

    # Without a project as well: the refused credentials are what to fix first.
    stub_env(%{"GITHUB_TOKEN" => "ghp_SECRET"})
    assert gcp(report(home)).state == "refused"

    credentials = Path.join(home, "gcp.json")
    File.write!(credentials, "{}")

    stub_env(%{
      "GITHUB_TOKEN" => "ghp_SECRET",
      "GOOGLE_APPLICATION_CREDENTIALS" => credentials,
      "GOOGLE_CLOUD_PROJECT" => "acme-ehos"
    })

    assert gcp(report(home)) == %{
             provider: "gcp",
             state: "refused",
             detail:
               "the key GOOGLE_APPLICATION_CREDENTIALS names gives no access token; replace it, " <>
                 "or unset GOOGLE_APPLICATION_CREDENTIALS and run " <>
                 "`gcloud auth application-default login`"
           }
  end

  test "an organisation policy that stops `server up` blocks the GCP account", %{tmp_dir: home} do
    with_gcp(home)
    stub_env(%{"GITHUB_TOKEN" => "ghp_SECRET", "GOOGLE_CLOUD_PROJECT" => "acme-ehos"})

    mock_gcloud(home, fn
      ["auth" | _args] ->
        {"ya29.SECRET\n", 0}

      ["org-policies", "describe", "compute.requireOsLogin" | _args] ->
        {policy_json("compute.requireOsLogin", [%{enforce: true}]), 0}

      ["org-policies", "describe", "compute.vmExternalIpAccess" | _args] ->
        {policy_json("compute.vmExternalIpAccess", [%{denyAll: true}]), 0}
    end)

    assert report(home) == %{
             tools: installed_tools(),
             ssh: "found",
             accounts: [
               oci_none(home),
               @aws_none,
               %{
                 provider: "gcp",
                 state: "blocked",
                 detail:
                   "gcloud's application default credentials, project acme-ehos, but an " <>
                     "organisation policy stops `ehosctl server up`"
               },
               @ovh_none
             ],
             gcp_policies: [
               policy(
                 "compute.requireOsLogin",
                 "blocks",
                 "enforced, so the server admits only OS Login users and `ehosctl server up` " <>
                   "waits for SSH that never admits its key; ask an organisation administrator " <>
                   "to lift it for project acme-ehos"
               ),
               policy(
                 "compute.vmExternalIpAccess",
                 "blocks",
                 "denies the server a public address, so `ehosctl server up` cannot make it; " <>
                   "ask an organisation administrator to lift it for project acme-ehos"
               )
             ],
             github_token: "set in GITHUB_TOKEN",
             ghcr_token: "not set",
             ready: false
           }
  end

  test "reads compute.vmExternalIpAccess as `server up` meets it", %{tmp_dir: home} do
    with_gcp(home)
    stub_env(%{"GITHUB_TOKEN" => "ghp_SECRET", "GOOGLE_CLOUD_PROJECT" => "acme-ehos"})

    states =
      for rules <- [
            [],
            [%{allowAll: true}],
            [%{denyAll: true}],
            [%{values: %{allowedValues: ["projects/acme-ehos/zones/z/instances/other"]}}],
            [%{values: %{deniedValues: ["projects/acme-ehos/zones/z/instances/other"]}}]
          ] do
        mock_gcloud(home, fn
          ["auth" | _args] -> {"ya29.SECRET\n", 0}
          ["org-policies", "describe", constraint | _args] -> {policy_json(constraint, rules), 0}
        end)

        Enum.map(report(home).gcp_policies, & &1.state)
      end

    assert states == [
             ["allows", "allows"],
             ["allows", "allows"],
             ["allows", "blocks"],
             ["allows", "blocks"],
             ["allows", "allows"]
           ]
  end

  test "says why the organisation policies could not be read, and stays ready", %{tmp_dir: home} do
    with_gcp(home)
    stub_env(%{"GITHUB_TOKEN" => "ghp_SECRET", "GOOGLE_CLOUD_PROJECT" => "acme-ehos"})

    mock_gcloud(home, fn
      ["auth" | _args] ->
        {"ya29.SECRET\n", 0}

      ["org-policies", "describe", "compute.requireOsLogin" | _args] ->
        {"ERROR: (gcloud.org-policies.describe) PERMISSION_DENIED: Organization Policy API " <>
           "has not been used in project 123 before or it is disabled. Enable it by visiting " <>
           "https://console.developers.google.com/apis/api/orgpolicy.googleapis.com/overview" <>
           "?project=123 then retry.\n", 1}

      ["org-policies", "describe", "compute.vmExternalIpAccess" | _args] ->
        {"\nERROR: (gcloud.org-policies.describe) INVALID_ARGUMENT: Project " <>
           "'projects/acme-ehos' not found or deleted.\n- '@type': " <>
           "type.googleapis.com/google.rpc.ErrorInfo\n  metadata:\n    service: " <>
           "orgpolicy.googleapis.com\n", 1}
    end)

    assert report(home) == %{
             tools: installed_tools(),
             ssh: "found",
             accounts: [
               oci_none(home),
               @aws_none,
               %{
                 provider: "gcp",
                 state: "found",
                 detail: "gcloud's application default credentials, project acme-ehos"
               },
               @ovh_none
             ],
             gcp_policies: [
               policy(
                 "compute.requireOsLogin",
                 "unknown",
                 "not checked: the Organization Policy API is off in project acme-ehos; turn " <>
                   "it on with `gcloud services enable orgpolicy.googleapis.com " <>
                   "--project=acme-ehos`"
               ),
               policy(
                 "compute.vmExternalIpAccess",
                 "unknown",
                 "not checked: ERROR: (gcloud.org-policies.describe) INVALID_ARGUMENT: " <>
                   "Project 'projects/acme-ehos' not found or deleted."
               )
             ],
             github_token: "set in GITHUB_TOKEN",
             ghcr_token: "not set",
             ready: true
           }

    mock_gcloud(home, fn
      ["auth" | _args] -> {"ya29.SECRET\n", 0}
      ["org-policies" | _args] -> {"Updates are available\n", 0}
    end)

    assert Enum.map(report(home).gcp_policies, & &1.detail) == [
             "not checked: gcloud's answer is not JSON",
             "not checked: gcloud's answer is not JSON"
           ]
  end

  # Each read waits for the other to start: read one after the other, the first gives up.
  test "reads both organisation policies at once", %{tmp_dir: home} do
    with_gcp(home)
    stub_env(%{"GITHUB_TOKEN" => "ghp_SECRET", "GOOGLE_CLOUD_PROJECT" => "acme-ehos"})
    started = :counters.new(1, [])

    mock_gcloud(home, fn
      ["auth" | _args] ->
        {"ya29.SECRET\n", 0}

      ["org-policies", "describe", constraint | _args] ->
        :counters.add(started, 1, 1)

        if both_started?(started, 50),
          do: {policy_json(constraint, []), 0},
          else: {"ERROR: the other read never started\n", 1}
    end)

    assert Enum.map(report(home).gcp_policies, & &1.state) == ["allows", "allows"]
  end

  test "--gcp-project names the project instead of GOOGLE_CLOUD_PROJECT", %{tmp_dir: home} do
    with_gcp(home)
    stub_home(home)
    stub_env(%{"GITHUB_TOKEN" => "ghp_SECRET", "GOOGLE_CLOUD_PROJECT" => "acme-ehos"})

    mock_gcloud(home, fn
      ["auth" | _args] ->
        {"ya29.SECRET\n", 0}

      ["org-policies", "describe", constraint, "--project=acme-other" | _args] ->
        {policy_json(constraint, []), 0}
    end)

    assert {:ok, %{json: %{accounts: accounts, ready: true}}} =
             Doctor.call([], %{flags: %{json: true}, options: %{gcp_project: "acme-other"}}, [])

    assert Enum.at(accounts, 2) == %{
             provider: "gcp",
             state: "found",
             detail: "gcloud's application default credentials, project acme-other"
           }
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

  defp oci_none(home), do: %{provider: "oci", state: "none", detail: "no #{home}/.oci/config"}

  defp installed_tools,
    do: [tool("opentofu", "installed"), tool("helm", "installed"), tool("kubectl", "installed")]

  defp ovh(report), do: Enum.find(report.accounts, &(&1.provider == "ovh"))

  defp both_started?(started, tries) do
    cond do
      :counters.get(started, 1) >= 2 ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(20)
        both_started?(started, tries - 1)
    end
  end

  defp gcp(report), do: Enum.find(report.accounts, &(&1.provider == "gcp"))

  # gcloud's application default credentials, as `gcloud auth application-default login` leaves
  # them.
  defp with_gcp(home) do
    File.mkdir_p!(Path.join(home, ".config/gcloud"))
    File.write!(Path.join(home, ".config/gcloud/application_default_credentials.json"), "{}")
    home
  end

  defp policy(constraint, state, detail),
    do: %{constraint: constraint, state: state, detail: detail}

  # The effective policy `gcloud org-policies describe --effective --format=json` prints.
  defp policy_json(constraint, rules) do
    JSON.encode!(%{
      name: "projects/123/policies/#{constraint}",
      spec: %{etag: "CAE=", rules: rules}
    })
  end

  # A pinned tool as the report gives it: `state`, and the command that installs one missing.
  defp tool(tool, state, install \\ nil) do
    {program, version} =
      %{
        "opentofu" => {"tofu", "1.13.1"},
        "helm" => {"helm", "4.3.0"},
        "kubectl" => {"kubectl", "1.37.1"}
      }[tool]

    %{tool: tool, program: program, version: version, state: state, install: install}
  end

  # The programs on the `PATH`, a map of names to paths.
  defp mock_find_executable(found),
    do: stub(Ehosctl.OSMock, :find_executable, &Map.get(found, &1))

  # gcloud on the `PATH` beside mise and ssh, answering its arguments with `gcloud`.
  defp mock_gcloud(dir, gcloud) do
    mock_find_executable(%{
      "mise" => "/usr/local/bin/mise",
      "ssh" => "/usr/bin/ssh",
      "gcloud" => "/usr/bin/gcloud"
    })

    mock_run(dir, [], gcloud)
  end

  # `mise which` finds every pinned tool but `missing`, each a file in `dir`, as mise prints it,
  # and gcloud, which may never ask a question, answers its arguments with `gcloud`.
  defp mock_run(dir, missing, gcloud \\ fn args -> flunk("gcloud #{inspect(args)}") end) do
    stub(Ehosctl.RunnerMock, :run, fn
      "/usr/local/bin/mise", ["which", program | _], _opts ->
        if program in missing do
          {"mise ERROR #{program} is not installed\n", 1}
        else
          path = Path.join(dir, program)
          File.write!(path, "")
          {path <> "\n", 0}
        end

      "/usr/bin/gcloud", args, opts ->
        assert {"CLOUDSDK_CORE_DISABLE_PROMPTS", "1"} in opts[:env]
        assert {"CLOUDSDK_CORE_HTTP_TIMEOUT", "20"} in opts[:env]
        gcloud.(args)
    end)

    :ok
  end
end
