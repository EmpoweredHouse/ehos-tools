defmodule EhosPlatform.Server.ProviderTest do
  use ExUnit.Case, async: true

  alias EhosPlatform.Server.Provider

  doctest Provider

  @no_env [env: &__MODULE__.no_env/1]

  def no_env(_name), do: nil

  describe "parse_oci_config/2" do
    test "reads the profile asked for, inheriting from [DEFAULT], and says when it lacks one" do
      contents = "[DEFAULT]\ntenancy=t1\nregion=r1\n[other]\ntenancy = t2\n"

      assert {:ok, %{tenancy: "t1", region: "r1"}} =
               Provider.parse_oci_config(contents, "DEFAULT")

      assert {:ok, %{tenancy: "t2", region: "r1"}} = Provider.parse_oci_config(contents, "other")
      assert {:error, message} = Provider.parse_oci_config("[other]\ntenancy=t2\n", "other")
      assert message =~ "[other]"
    end
  end

  describe "variables/3" do
    test "on AWS: the option, then the recorded profile, then AWS_PROFILE, then default" do
      env = fn "AWS_PROFILE" -> "from-env" end
      recorded = %{"provider" => "aws", "aws_profile" => "recorded", "region" => "eu-west-1"}

      assert {:ok, %{aws_profile: "given", region: "us-east-1"}} =
               Provider.variables(
                 :aws,
                 [aws_profile: "given", region: "us-east-1", env: env],
                 recorded
               )

      # An AWS_PROFILE set later in a shell does not move the installation to another profile.
      assert {:ok, %{aws_profile: "recorded", region: "eu-west-1"}} =
               Provider.variables(:aws, [env: env], recorded)

      assert {:ok, %{aws_profile: "from-env"}} = Provider.variables(:aws, [env: env], nil)

      assert {:ok, %{aws_profile: "default", region: "eu-central-1"}} =
               Provider.variables(:aws, [env: fn _name -> "" end], nil)
    end

    test "on AWS: a recorded account pins the next run" do
      recorded = %{"provider" => "aws", "aws_account_id" => "111122223333"}

      assert {:ok, %{aws_account_id: "111122223333"}} =
               Provider.variables(:aws, @no_env, recorded)

      assert {:ok, %{aws_account_id: ""}} = Provider.variables(:aws, @no_env, nil)
    end

    test "on GCP: a project is required, from the option, the record, or GOOGLE_CLOUD_PROJECT" do
      assert {:error, message} = Provider.variables(:gcp, @no_env, nil)
      assert message =~ "--gcp-project" and message =~ "application-default login"

      env = fn "GOOGLE_CLOUD_PROJECT" -> "from-env" end

      assert {:ok, %{project: "from-env", region: "europe-west3"}} =
               Provider.variables(:gcp, [env: env], nil)

      assert {:ok, %{project: "recorded"}} =
               Provider.variables(:gcp, [env: env], %{"project" => "recorded"})

      assert {:ok, %{project: "given"}} =
               Provider.variables(:gcp, [gcp_project: "given", env: env], nil)
    end

    test "on Oracle: refuses --region, which is the profile's" do
      assert {:error, message} = Provider.variables(:oci, [region: "eu-amsterdam-1"], nil)
      assert message =~ "--region is for AWS and GCP"
    end

    test "on Oracle: says when the configuration file is missing" do
      assert {:error, message} =
               Provider.variables(:oci, [oci_config: "/nonexistent/oci-config"], nil)

      assert message =~ "/nonexistent/oci-config is missing"
    end
  end

  describe "size/3 (D-84)" do
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

      # Nothing given or recorded is the module's default, which `up` does not repeat.
      assert Provider.size(:oci, [], %{}) == {:ok, %{}}
    end

    test "refuses another provider's options and values no provider takes" do
      assert {:error, message} = Provider.size(:aws, [ocpus: 2, memory_gb: 12], %{})
      assert message =~ "--ocpus and --memory-gb does not size" and message =~ "--instance-type"

      assert {:error, message} = Provider.size(:oci, [instance_type: "t4g.large"], %{})
      assert message =~ "--instance-type" and message =~ "--ocpus and --memory-gb"

      assert {:error, message} = Provider.size(:oci, [ocpus: 0], %{})
      assert message =~ "--ocpus is a whole number from 1"

      for type <- ["", "T4G.LARGE", "t4g.large; rm -rf", String.duplicate("a", 64)] do
        assert {:error, message} = Provider.size(:gcp, [instance_type: type], %{})
        assert message =~ "--instance-type"
      end
    end
  end

  describe "place/2 and moved/3" do
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
  end

  test "each provider has its module, instance and console" do
    for name <- Provider.names() do
      {:ok, provider} = Provider.parse(name)
      assert Provider.name(provider) == name
      assert Provider.module(provider) == "deploy/tofu/#{name}"
      assert Provider.instance(provider) =~ ~r/\.server\z/
      assert Provider.console(provider) =~ "console"
    end
  end

  test "a capacity hint only for the provider's own words" do
    assert Provider.capacity_hint(:oci, "Out of host capacity") =~ "Ampere"
    assert Provider.capacity_hint(:gcp, "ZONE_RESOURCE_POOL_EXHAUSTED") =~ "zones"
    assert Provider.capacity_hint(:aws, "Out of host capacity") == ""
    assert Provider.capacity_hint(:oci, "InsufficientInstanceCapacity") == ""
  end

  test "on AWS, every exported credential is taken out of OpenTofu's environment" do
    for name <- ~w(AWS_ACCESS_KEY_ID AWS_ACCESS_KEY AWS_PROFILE AWS_WEB_IDENTITY_TOKEN_FILE),
        do: assert({name, nil} in Provider.env(:aws))

    assert Provider.env(:gcp) == []
  end
end
