defmodule EhosPlatform.Server.ProviderTest do
  use ExUnit.Case, async: true

  import Hammox

  alias EhosPlatform.EnvMock
  alias EhosPlatform.Server.Provider

  doctest Provider

  setup :verify_on_exit!

  # The environment holds nothing a test does not set, and the system puts the operator's home at
  # a path no test creates.
  setup do
    mock_env(%{})
    stub(EnvMock, :user_home, fn -> "/home/operator" end)
    :ok
  end

  @env [env: EnvMock]
  @project String.duplicate("ab", 16)

  # What OpenTofu's environment takes out on OVHcloud: every OS_* variable that could stand in for
  # the clouds.yaml entry, add to it or weaken how it is used (eh-os D-127).
  @openstack_variables ~w(OS_CLOUD OS_AUTH_URL OS_AUTH_TYPE OS_USERNAME OS_USER_ID OS_PASSWORD
                          OS_TOKEN OS_AUTH_TOKEN OS_PROJECT_ID OS_PROJECT_NAME OS_TENANT_ID
                          OS_TENANT_NAME OS_USER_DOMAIN_ID OS_USER_DOMAIN_NAME
                          OS_PROJECT_DOMAIN_ID OS_PROJECT_DOMAIN_NAME OS_DOMAIN_ID OS_DOMAIN_NAME
                          OS_DEFAULT_DOMAIN OS_SYSTEM_SCOPE OS_REGION_NAME
                          OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_NAME
                          OS_APPLICATION_CREDENTIAL_SECRET OS_INTERFACE OS_ENDPOINT_TYPE
                          OS_IDENTITY_API_VERSION OS_INSECURE OS_CACERT OS_CERT OS_KEY OS_SWAUTH
                          OS_DELAYED_AUTH OS_ALLOW_REAUTH OS_DEBUG OS_CLIENT_CONFIG_FILE)

  describe "parse_oci_config/2" do
    test "reads the profile asked for, inheriting from [DEFAULT]" do
      contents = "[DEFAULT]\ntenancy=t1\nregion=r1\n[other]\ntenancy = t2\n"

      assert Provider.parse_oci_config(contents, "DEFAULT") ==
               {:ok, %{tenancy: "t1", region: "r1"}}

      assert Provider.parse_oci_config(contents, "other") == {:ok, %{tenancy: "t2", region: "r1"}}
    end

    test "says when the profile lacks a tenancy or a region" do
      assert Provider.parse_oci_config("[other]\ntenancy=t2\n", "other") ==
               {:error, "~/.oci/config has no `tenancy` and `region` in its [other] profile"}
    end
  end

  describe "variables/3" do
    test "on AWS: the option, then the recorded profile, then AWS_PROFILE, then default" do
      mock_env(%{"AWS_PROFILE" => "from-env"})
      recorded = %{"provider" => "aws", "aws_profile" => "recorded", "region" => "eu-west-1"}

      assert Provider.variables(
               :aws,
               [aws_profile: "given", region: "us-east-1"] ++ @env,
               recorded
             ) == {:ok, %{aws_profile: "given", region: "us-east-1", aws_account_id: ""}}

      # An AWS_PROFILE set later in a shell does not move the installation to another profile.
      assert Provider.variables(:aws, @env, recorded) ==
               {:ok, %{aws_profile: "recorded", region: "eu-west-1", aws_account_id: ""}}

      assert Provider.variables(:aws, @env, nil) ==
               {:ok, %{aws_profile: "from-env", region: "eu-central-1", aws_account_id: ""}}

      # Set but empty is not set.
      mock_env(%{"AWS_PROFILE" => ""})

      assert Provider.variables(:aws, @env, nil) ==
               {:ok, %{aws_profile: "default", region: "eu-central-1", aws_account_id: ""}}
    end

    test "on AWS: a recorded account pins the next run" do
      recorded = %{"provider" => "aws", "aws_account_id" => "111122223333"}

      assert Provider.variables(:aws, @env, recorded) ==
               {:ok,
                %{aws_profile: "default", region: "eu-central-1", aws_account_id: "111122223333"}}
    end

    test "on GCP: the project from the option, the record, or GOOGLE_CLOUD_PROJECT" do
      mock_env(%{"GOOGLE_CLOUD_PROJECT" => "from-env"})

      assert Provider.variables(:gcp, @env, nil) ==
               {:ok, %{project: "from-env", region: "europe-west3"}}

      assert Provider.variables(:gcp, @env, %{"project" => "recorded"}) ==
               {:ok, %{project: "recorded", region: "europe-west3"}}

      assert Provider.variables(:gcp, [gcp_project: "given"] ++ @env, nil) ==
               {:ok, %{project: "given", region: "europe-west3"}}
    end

    test "on GCP: refuses without a project, and says how to name one" do
      assert Provider.variables(:gcp, @env, nil) ==
               {:error,
                "Name the GCP project with --gcp-project, and sign in with " <>
                  "`gcloud auth application-default login` (D-83)"}
    end

    @tag :tmp_dir
    test "on OVHcloud: a clouds.yaml entry, from the option, the record, OS_CLOUD, or ovh",
         %{tmp_dir: dir} do
      opts = [clouds_yaml: write_clouds_yaml(dir)] ++ @env

      assert Provider.variables(:ovh, opts, nil) ==
               {:ok, %{os_cloud: "ovh", region: "GRA11", project_id: ""}}

      recorded = %{
        "provider" => "ovh",
        "os_cloud" => "acme",
        "region" => "SBG5",
        "project_id" => @project
      }

      assert Provider.variables(:ovh, opts, recorded) ==
               {:ok, %{os_cloud: "acme", region: "SBG5", project_id: @project}}

      mock_env(%{"OS_CLOUD" => "acme"})

      assert Provider.variables(:ovh, opts, nil) ==
               {:ok, %{os_cloud: "acme", region: "GRA11", project_id: ""}}
    end

    @tag :tmp_dir
    test "on OVHcloud: refuses an entry clouds.yaml does not have, naming none of its secrets",
         %{tmp_dir: dir} do
      clouds = write_clouds_yaml(dir)

      assert Provider.variables(:ovh, [os_cloud: "other", clouds_yaml: clouds] ++ @env, nil) ==
               {:error,
                "#{clouds} has no entry \"other\" under `clouds`; name the entry with --os-cloud"}
    end

    @tag :tmp_dir
    test "on OVHcloud: refuses a clouds.yaml that is not YAML", %{tmp_dir: dir} do
      clouds = Path.join(dir, "clouds.yaml")
      File.write!(clouds, "not: [yaml")

      assert Provider.variables(:ovh, [clouds_yaml: clouds] ++ @env, nil) ==
               {:error,
                "#{clouds} cannot be read as OpenStack's clouds.yaml. Download the clouds.yaml " <>
                  "of an OpenStack user of your OVHcloud project (D-127)"}
    end

    test "on OVHcloud: refuses when there is no clouds.yaml" do
      assert Provider.variables(:ovh, [clouds_yaml: nil] ++ @env, nil) ==
               {:error,
                "No clouds.yaml in ~/.config/openstack or OS_CLIENT_CONFIG_FILE. Download the " <>
                  "clouds.yaml of an OpenStack user of your OVHcloud project (D-127)"}
    end

    test "on Oracle: refuses --region, which is the profile's" do
      assert Provider.variables(:oci, [region: "eu-amsterdam-1"], nil) ==
               {:error,
                "On Oracle the region is the profile's, in #{Path.expand("~/.oci/config")}; " <>
                  "--region is for AWS, GCP and OVHcloud"}
    end

    test "on Oracle: says when the configuration file is missing" do
      assert Provider.variables(:oci, [oci_config: "/nonexistent/oci-config"], nil) ==
               {:error,
                "/nonexistent/oci-config is missing. Create an API key in Oracle Cloud's " <>
                  "console (D-77)"}
    end
  end

  describe "clouds_yaml/2" do
    @tag :tmp_dir
    test "is OS_CLIENT_CONFIG_FILE's, else the home directory's", %{tmp_dir: dir} do
      home = Path.join(dir, "home")
      File.mkdir_p!(Path.join(home, ".config/openstack"))
      in_home = Path.join(home, ".config/openstack/clouds.yaml")
      File.write!(in_home, "clouds: {}\n")

      assert Provider.clouds_yaml(nil, home) == in_home
      assert Provider.clouds_yaml("", home) == in_home
      assert Provider.clouds_yaml("/elsewhere/c.yaml", home) == "/elsewhere/c.yaml"
    end
  end

  describe "os_cloud/2" do
    @tag :tmp_dir
    test "reads the clouds.yaml under the operator's home when none is named", %{tmp_dir: home} do
      clouds = Path.join(home, ".config/openstack/clouds.yaml")
      File.mkdir_p!(Path.dirname(clouds))
      File.write!(clouds, "clouds:\n  ovh:\n    auth: {password: s3cret}\n")
      stub(EnvMock, :user_home, fn -> home end)

      assert Provider.os_cloud("ovh", @env) == {:ok, clouds}
    end

    @tag :tmp_dir
    test "takes a value that holds `*` but no alias", %{tmp_dir: dir} do
      clouds = Path.join(dir, "clouds.yaml")
      File.write!(clouds, "clouds:\n  ovh:\n    auth: {password: \"p*ss *word\"}\n")

      assert Provider.os_cloud("ovh", clouds_yaml: clouds) == {:ok, clouds}
    end

    # A few bytes of nested aliases expand past any memory when decoded.
    @tag :tmp_dir
    test "refuses a clouds.yaml with aliases before it is decoded", %{tmp_dir: dir} do
      clouds = Path.join(dir, "clouds.yaml")
      File.write!(clouds, "a: &a [x, x]\nb: &b [*a, *a]\nclouds:\n  ovh: {auth: *b}\n")

      assert Provider.os_cloud("ovh", clouds_yaml: clouds) ==
               {:error,
                "#{clouds} seems to use YAML aliases (`*name`), which EHOS does not read: write " <>
                  "them out, or quote a value that holds `*` after a space, a comma, a colon or " <>
                  "a bracket"}
    end
  end

  describe "size/3" do
    test "takes the provider's own options, and keeps the recorded size for what is not given" do
      recorded = %{"ocpus" => 1, "memory_gbs" => 6, "instance_type" => "m7g.large"}

      assert Provider.size(:oci, [], recorded) == {:ok, %{"ocpus" => 1, "memory_gbs" => 6}}

      assert Provider.size(:oci, [memory_gb: 8], recorded) ==
               {:ok, %{"ocpus" => 1, "memory_gbs" => 8}}

      assert Provider.size(:aws, [], recorded) == {:ok, %{"instance_type" => "m7g.large"}}

      assert Provider.size(:aws, [instance_type: "t4g.xlarge"], recorded) ==
               {:ok, %{"instance_type" => "t4g.xlarge"}}

      assert Provider.size(:gcp, [instance_type: "e2-standard-4"], %{}) ==
               {:ok, %{"machine_type" => "e2-standard-4"}}

      assert Provider.size(:ovh, [instance_type: "b3-8"], %{"flavor_name" => "d2-8"}) ==
               {:ok, %{"flavor_name" => "b3-8"}}

      # Nothing given or recorded is the module's default, which `up` does not repeat.
      assert Provider.size(:oci, [], %{}) == {:ok, %{}}
    end

    test "refuses another provider's options" do
      assert Provider.size(:aws, [ocpus: 2, memory_gb: 12], %{}) ==
               {:error,
                "--ocpus and --memory-gb does not size a server on aws; give --instance-type " <>
                  "there (D-84)"}

      assert Provider.size(:oci, [instance_type: "t4g.large"], %{}) ==
               {:error,
                "--instance-type does not size a server on oci; give --ocpus and --memory-gb " <>
                  "there (D-84)"}

      assert Provider.size(:ovh, [ocpus: 2], %{}) ==
               {:error,
                "--ocpus does not size a server on ovh; give --instance-type there (D-84)"}
    end

    test "refuses values no provider takes" do
      assert Provider.size(:oci, [ocpus: 0], %{}) ==
               {:error, "--ocpus is a whole number from 1, not 0"}

      for type <- ["", "T4G.LARGE", "t4g.large; rm -rf", String.duplicate("a", 64)] do
        assert Provider.size(:gcp, [instance_type: type], %{}) ==
                 {:error,
                  "--instance-type is a type's name, such as t4g.large, not #{inspect(type)}"}
      end
    end
  end

  describe "place/2, moved/3 and pinned_output/1" do
    test "the place is the provider, its identity and the profile, nothing else" do
      vars = %{
        aws_profile: "acme",
        aws_account_id: "",
        region: "eu-central-1",
        ssh_from: ["192.0.2.1/32"],
        name: "trial"
      }

      assert Provider.place(:aws, vars) == %{
               "provider" => "aws",
               "aws_profile" => "acme",
               "region" => "eu-central-1"
             }
    end

    test "on OVHcloud, the place is the entry and the region, and the project once known" do
      vars = %{os_cloud: "acme", region: "GRA11", project_id: "", flavor_name: "d2-8", name: "t"}

      assert Provider.place(:ovh, vars) == %{
               "provider" => "ovh",
               "os_cloud" => "acme",
               "region" => "GRA11"
             }

      assert Provider.place(:ovh, %{vars | project_id: @project}) == %{
               "provider" => "ovh",
               "os_cloud" => "acme",
               "region" => "GRA11",
               "project_id" => @project
             }

      assert Provider.pinned_output(:ovh) == {"project_id", "project_id"}
    end

    test "names the identity a change would leave, and only what the place already holds" do
      place = %{"provider" => "aws", "aws_profile" => "a", "region" => "eu-central-1"}

      assert Provider.moved(:aws, place, %{aws_profile: "b", region: "eu-central-1"}) == []

      assert Provider.moved(:aws, place, %{region: "us-east-1"}) ==
               ["region eu-central-1 → us-east-1"]

      pinned = Map.put(place, "aws_account_id", "111122223333")
      other = %{aws_account_id: "444455556666", region: "eu-central-1"}

      assert Provider.moved(:aws, pinned, other) ==
               ["aws_account_id 111122223333 → 444455556666"]

      assert Provider.moved(:gcp, nil, %{project: "x"}) == []
    end

    test "on OVHcloud, names another project" do
      place = %{
        "provider" => "ovh",
        "os_cloud" => "acme",
        "region" => "GRA11",
        "project_id" => @project
      }

      other = String.duplicate("cd", 16)

      assert Provider.moved(:ovh, place, %{os_cloud: "acme", region: "GRA11", project_id: other}) ==
               ["project_id #{@project} → #{other}"]
    end
  end

  describe "name/1, module/1, instance/1 and console/1" do
    test "each provider has its module, its instance and where its console shows host keys" do
      assert for(name <- Provider.names(), do: describe_provider(name)) == [
               {"aws", "deploy/tofu/aws", "aws_instance.server",
                "the instance's system log in AWS's console (Actions, Monitor and troubleshoot)"},
               {"gcp", "deploy/tofu/gcp", "google_compute_instance.server",
                "the serial port output of the instance in Google Cloud's console"},
               {"oci", "deploy/tofu/oci", "oci_core_instance.server",
                "the console history of the instance in Oracle's console"},
               {"ovh", "deploy/tofu/ovh", "openstack_compute_instance_v2.server",
                "the instance's console log (`openstack console log show <server>`, or " <>
                  "OVHcloud's Control Panel)"}
             ]
    end
  end

  describe "capacity_hint/2" do
    test "says what to try when the provider says it has no capacity" do
      assert Provider.capacity_hint(:oci, "Out of host capacity") ==
               "\nOracle has no Ampere capacity there now: run it again later, or, where the " <>
                 "region has more than one availability domain, with another " <>
                 "--availability-domain (from 0)"

      assert Provider.capacity_hint(:gcp, "ZONE_RESOURCE_POOL_EXHAUSTED") ==
               "\nThe provider has no machine of that type in that zone now: run it again " <>
                 "later, or with another --availability-domain (from 0), which picks another " <>
                 "of the region's zones"

      assert Provider.capacity_hint(:ovh, "No valid host was found. ") ==
               "\nOVHcloud has no machine of that flavor in that region now: run it again " <>
                 "later, or with another --instance-type or --region"
    end

    test "says nothing for another provider's words" do
      assert Provider.capacity_hint(:aws, "Out of host capacity") == ""
      assert Provider.capacity_hint(:oci, "InsufficientInstanceCapacity") == ""
      assert Provider.capacity_hint(:ovh, "Out of host capacity") == ""
    end
  end

  describe "env/1 and env/2" do
    test "on AWS, takes every exported credential out of OpenTofu's environment" do
      assert Provider.env(:aws) ==
               for(
                 name <-
                   ~w(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
                      AWS_SECURITY_TOKEN AWS_ACCESS_KEY AWS_SECRET_KEY AWS_PROFILE
                      AWS_DEFAULT_PROFILE AWS_WEB_IDENTITY_TOKEN_FILE AWS_ROLE_ARN
                      AWS_ROLE_SESSION_NAME AWS_CONTAINER_CREDENTIALS_FULL_URI
                      AWS_CONTAINER_CREDENTIALS_RELATIVE_URI AWS_CONTAINER_AUTHORIZATION_TOKEN),
                 do: {name, nil}
               )
    end

    test "on GCP and Oracle, changes nothing" do
      assert Provider.env(:gcp) == []
      assert Provider.env(:oci) == []
    end

    # eh-os D-127: the clouds.yaml entry is the only source, and OpenTofu reads the file ehosctl
    # checked.
    @tag :tmp_dir
    test "on OVHcloud, takes every OpenStack credential out and names the clouds.yaml checked",
         %{tmp_dir: home} do
      clouds = Path.join(home, ".config/openstack/clouds.yaml")
      File.mkdir_p!(Path.dirname(clouds))
      File.write!(clouds, "clouds: {}\n")
      mock_env(%{"OS_CLIENT_CONFIG_FILE" => clouds})

      expected =
        for name <- @openstack_variables,
            do: if(name == "OS_CLIENT_CONFIG_FILE", do: {name, clouds}, else: {name, nil})

      assert Provider.env(:ovh, clouds_yaml: clouds) == expected
      assert Provider.env(:ovh, @env) == expected
    end

    test "on OVHcloud without a clouds.yaml, takes OS_CLIENT_CONFIG_FILE out too" do
      assert Provider.env(:ovh, clouds_yaml: nil) ==
               for(name <- @openstack_variables, do: {name, nil})
    end
  end

  defp describe_provider(name) do
    {:ok, provider} = Provider.parse(name)

    {Provider.name(provider), Provider.module(provider), Provider.instance(provider),
     Provider.console(provider)}
  end

  defp write_clouds_yaml(dir) do
    clouds = Path.join(dir, "clouds.yaml")

    File.write!(clouds, """
    clouds:
      ovh:
        auth: {auth_url: "https://auth.cloud.ovh.net/v3", password: s3cret}
      acme:
        region_name: SBG5
    """)

    clouds
  end

  defp mock_env(variables), do: stub(EnvMock, :get, &Map.get(variables, &1))
end
