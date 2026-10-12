defmodule EhosPlatform.InstallTest do
  use ExUnit.Case, async: true

  import Mox

  alias EhosPlatform.CommandRunnerMock
  alias EhosPlatform.Install
  alias EhosPlatform.Source

  doctest Install

  setup :verify_on_exit!

  @moduletag :tmp_dir

  @digest "sha256:" <> String.duplicate("ab", 32)
  # An eh-os checkout the commands are told about; every command is the mock's.
  @source Source.checkout("/src/eh-os")
  # Test CAs, certificates only, made with openssl: one whose name constraints exclude every IP
  # address, as the installation's CA's do, and one constraining names alone, as it did before.
  @ca_pem File.read!("test/support/fixtures/certificates/ca-excluding-ip.pem")
  @names_only_pem File.read!("test/support/fixtures/certificates/ca-names-only.pem")
  @host "ehos.152-70-8-238.sslip.io"
  @token "ghp_not_a_real_token_0123456789"

  describe "for_host/2" do
    test "writes the installation's CA and its admission policy for another host" do
      rendered = "local-ca.yaml" |> Install.manifest() |> File.read!() |> Install.for_host(@host)

      refute rendered =~ "localhost"
      documents = YamlElixir.read_all_from_string!(rendered)

      [certificate] = Enum.filter(documents, &(&1["kind"] == "Certificate"))
      assert certificate["spec"]["nameConstraints"]["permitted"]["dnsDomains"] == [@host]
      # A constraint on names alone leaves every IP address open (RFC 5280).
      assert certificate["spec"]["nameConstraints"]["excluded"]["ipRanges"] == [
               "0.0.0.0/0",
               "::/0"
             ]

      [policy] = Enum.filter(documents, &(&1["kind"] == "ValidatingAdmissionPolicy"))
      rule = Enum.map_join(policy["spec"]["validations"], "\n", & &1["expression"])
      assert rule =~ "name == '#{@host}'"
      assert rule =~ ~S"\\.ehos\\.152-70-8-238\\.sslip\\.io$"
    end

    test "writes the CoreDNS rule for another host, and nothing broader" do
      rendered =
        "coredns-custom.yaml" |> Install.manifest() |> File.read!() |> Install.for_host(@host)

      %{"data" => %{"ehos.override" => rule}} = YamlElixir.read_from_string!(rendered)
      assert rule =~ ~S"^(.+\.)?ehos\.152-70-8-238\.sslip\.io\.$"
      refute rendered =~ "localhost"
    end
  end

  describe "excludes_every_ip?/1" do
    test "tells a CA whose name constraints exclude every IP address from one that constrains names alone" do
      assert Install.excludes_every_ip?(@ca_pem)
      refute Install.excludes_every_ip?(@names_only_pem)
      refute Install.excludes_every_ip?("not a certificate")
    end
  end

  describe "kubectl_args/2" do
    test "names the context, and the kubeconfig when the target has one" do
      local = %Install{context: "k3d-ehos", host: "ehos.localhost", source: @source}
      server = %Install{context: "ehos-trial", host: @host, kubeconfig: "/k", source: @source}

      assert Install.kubectl_args(local, ["get", "nodes"]) == [
               "--context",
               "k3d-ehos",
               "get",
               "nodes"
             ]

      assert Install.kubectl_args(server, ["get", "nodes"]) ==
               ["--kubeconfig", "/k", "--context", "ehos-trial", "get", "nodes"]
    end
  end

  describe "server/1" do
    setup %{tmp_dir: tmp_dir} do
      home = Path.join(tmp_dir, "ehos")
      dir = Path.join(home, "trial")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "kubeconfig"), "{}")
      File.write!(Path.join(dir, "tunnel.json"), ~s({"address":"152.70.8.238","port":16443}))

      opts = [
        runner: CommandRunnerMock,
        source: @source,
        home: home,
        digest: @digest,
        token: @token,
        username: "octocat",
        sleep: fn _ms -> :ok end
      ]

      %{opts: opts, dir: dir}
    end

    test "installs the prerequisites, the CA for the server's host and the chart, in the installation's context",
         %{opts: opts, dir: dir} do
      calls = record_calls()

      assert {:ok, message} = Install.server(opts)
      assert message =~ "https://#{@host}" and message =~ "ghcr.io/empoweredhouse/ehos@#{@digest}"
      assert message =~ Path.join(dir, "ca.crt")
      refute message =~ @token

      kubeconfig = Path.join(dir, "kubeconfig")

      for {program, args} <- calls.(), program in ["kubectl", "helm"], hd(args) != "package" do
        assert value_of(args, "--kubeconfig") == kubeconfig, inspect({program, args})

        assert value_of(args, "--context") == "ehos-trial" or
                 value_of(args, "--kube-context") == "ehos-trial"
      end

      steps = for {program, args} <- calls.(), do: {program, Enum.take(step(args), 3)}

      assert [
               {"kubectl", ["get", "nodes", "-o"]},
               {"kubectl", ["apply", "--server-side", "--force-conflicts"]},
               {"kubectl", ["annotate", "secret", "ehos-pull-credential"]},
               {"helm", ["list", "--namespace", "cnpg-system"]},
               {"helm", ["upgrade", "--install", "cnpg"]},
               {"helm", ["list", "--namespace", "cert-manager"]},
               {"helm", ["upgrade", "--install", "cert-manager"]},
               {"helm", ["list", "--namespace", "cert-manager"]},
               {"helm", ["upgrade", "--install", "trust-manager"]},
               {"kubectl", ["get", "secret", "ehos-local-ca"]},
               {"kubectl", ["apply", "-f", ca]},
               {"kubectl", ["wait", "--for=condition=Ready", "certificate/ehos-local-ca"]},
               {"kubectl", ["get", "secret", "ehos-local-ca"]},
               {"kubectl", ["get", "secret", "ehos-local-ca"]},
               {"kubectl", ["delete" | _]},
               {"kubectl", ["apply", "-f", coredns]},
               {"kubectl", ["patch", "--type=merge", "-p"]},
               {"kubectl", ["rollout", "status", "--timeout=2m"]},
               {"kubectl", ["get", "secret", "ehos-local-ca"]},
               {"helm", ["package", "/src/eh-os/deploy/charts/ehos", "--destination"]},
               {"helm", ["upgrade", "--install", "ehos"]},
               {"kubectl", ["wait", "--for=condition=Ready", "certificate/ehos-governance-tls"]}
             ] = steps

      # The CA and the CoreDNS rule are rendered for the server's host, not applied as written.
      refute ca == Install.manifest("local-ca.yaml")
      refute coredns == Install.manifest("coredns-custom.yaml")

      {_helm, chart} =
        Enum.find(calls.(), &match?({"helm", ["upgrade", "--install", "ehos" | _]}, &1))

      assert "image.repository=ghcr.io/empoweredhouse/ehos" in chart
      assert "image.digest=#{@digest}" in chart
      assert "governance.host=#{@host}" in chart
      assert "environments.allowedImagePrefixes={ghcr.io/empoweredhouse/}" in chart
      assert "environments.imagePullSecret=ehos-pull-credential" in chart
      assert "imagePullSecrets[0].name=ehos-pull-credential" in chart

      assert value_of(chart, "--set-file") ==
               "environments.caCertificate=#{Path.join(dir, "ca.crt")}"

      # D-90: an installation `up` did not make says only its name.
      assert value_of(chart, "--set-json") == ~s(installation={"name":"trial"})

      assert File.read!(Path.join(dir, "ca.crt")) == @ca_pem

      assert dir |> Path.join("install.json") |> File.read!() |> Jason.decode!() == %{
               "digest" => @digest,
               "host" => @host,
               "repository" => "ghcr.io/empoweredhouse/ehos"
             }
    end

    # D-90: what the installation's page says it is, from what `up` recorded.
    test "describes the installation to the chart from where `up` made it", %{
      opts: opts,
      dir: dir
    } do
      for {place, vars, description} <- [
            {%{"provider" => "aws", "aws_account_id" => "1", "region" => "eu-central-1"},
             %{"instance_type" => "t4g.large"},
             %{"provider" => "aws", "region" => "eu-central-1", "size" => "t4g.large"}},
            {%{"provider" => "gcp", "project" => "p", "region" => "europe-west3"},
             %{"machine_type" => "e2-standard-4"},
             %{"provider" => "gcp", "region" => "europe-west3", "size" => "e2-standard-4"}},
            {%{"provider" => "oci", "tenancy_ocid" => "t", "region" => "eu-frankfurt-1"},
             %{"ocpus" => 4, "memory_gbs" => 24},
             %{"provider" => "oci", "region" => "eu-frankfurt-1", "size" => "4 OCPUs, 24 GB"}},
            # The module's default size is not recorded, so it is not said.
            {%{"provider" => "oci", "tenancy_ocid" => "t", "region" => "eu-frankfurt-1"}, %{},
             %{"provider" => "oci", "region" => "eu-frankfurt-1"}}
          ] do
        File.write!(Path.join(dir, "installation.json"), Jason.encode!(place))
        File.write!(Path.join(dir, "server.tfvars.json"), Jason.encode!(vars))
        calls = record_calls()

        assert {:ok, _message} = Install.server(opts)

        {_helm, chart} =
          Enum.find(calls.(), &match?({"helm", ["upgrade", "--install", "ehos" | _]}, &1))

        assert "installation=" <> json = value_of(chart, "--set-json")
        assert Jason.decode!(json) == Map.put(description, "name", "trial")
      end
    end

    test "describes an Oracle server made before installation.json from its variables", %{
      opts: opts,
      dir: dir
    } do
      File.write!(Path.join(dir, "terraform.tfstate"), "{}")

      File.write!(
        Path.join(dir, "server.tfvars.json"),
        ~s({"tenancy_ocid":"t","region":"eu-frankfurt-1","ocpus":2})
      )

      calls = record_calls()
      assert {:ok, _message} = Install.server(opts)

      {_helm, chart} =
        Enum.find(calls.(), &match?({"helm", ["upgrade", "--install", "ehos" | _]}, &1))

      assert "installation=" <> json = value_of(chart, "--set-json")

      assert Jason.decode!(json) == %{
               "name" => "trial",
               "provider" => "oci",
               "region" => "eu-frankfurt-1",
               "size" => "2 OCPUs"
             }
    end

    test "writes the pull credential from a file only this user reads, never from an argument",
         %{opts: opts} do
      test_pid = self()

      record_calls(fn
        "kubectl", args ->
          case step(args) do
            ["apply", "--server-side", "--force-conflicts", "-f", path] ->
              if String.ends_with?(path, "secret.json") do
                send(test_pid, {:credential, File.read!(path), File.stat!(path).mode, path})
              end

              nil

            _other ->
              nil
          end

        _program, _args ->
          nil
      end)

      assert {:ok, _message} = Install.server(opts)

      assert_received {:credential, contents, mode, path}
      assert Bitwise.band(mode, 0o777) == 0o600
      refute File.exists?(path)

      %{"items" => [namespace, secret]} = Jason.decode!(contents)
      assert namespace["metadata"]["name"] == "ehos-system"
      assert secret["type"] == "kubernetes.io/dockerconfigjson"

      assert secret["metadata"] == %{
               "name" => "ehos-pull-credential",
               "namespace" => "ehos-system"
             }

      config = secret["data"][".dockerconfigjson"] |> Base.decode64!() |> Jason.decode!()
      assert %{"auths" => %{"ghcr.io" => %{"username" => "octocat", "auth" => auth}}} = config
      assert Base.decode64!(auth) == "octocat:#{@token}"
    end

    test "never puts the token on a command line", %{opts: opts} do
      calls = record_calls()
      assert {:ok, _message} = Install.server(opts)

      for {_program, args} <- calls.(), arg <- args do
        refute arg =~ @token
        refute arg =~ Base.encode64("octocat:#{@token}")
      end
    end

    test "keeps the token out of what a failed apply printed", %{opts: opts} do
      record_calls(fn
        "kubectl", args ->
          if match?(["apply", "--server-side", "--force-conflicts", "-f", _], step(args)) and
               String.ends_with?(List.last(args), "secret.json"),
             do: {"error: the server rejected #{@token}", 1}

        _program, _args ->
          nil
      end)

      assert {:error, message} = Install.server(opts)
      refute message =~ @token
      assert message =~ "[the token]"
    end

    test "keeps the credential the cluster holds when no token is given", %{opts: opts} do
      calls = record_calls(pull_credential: true)

      assert {:ok, _message} = Install.server(Keyword.put(opts, :token, ""))

      refute Enum.any?(calls.(), fn {_p, args} ->
               Enum.any?(args, &String.ends_with?(&1, "secret.json"))
             end)
    end

    test "says how to give a token when there is none, in the cluster or the environment", %{
      opts: opts
    } do
      record_calls(pull_credential: false)

      assert {:error, message} = Install.server(Keyword.put(opts, :token, ""))
      assert message =~ "GHCR_TOKEN" and message =~ "read:packages"
    end

    test "asks the GitHub CLI whose token it is when no user is given", %{opts: opts} do
      calls =
        record_calls(fn
          "gh", ["api", "user", "--jq", ".login"] -> {"octocat\n", 0}
          _program, _args -> nil
        end)

      assert {:ok, _message} = Install.server(Keyword.put(opts, :username, nil))
      assert Enum.any?(calls.(), &(&1 == {"gh", ["api", "user", "--jq", ".login"]}))
    end

    test "takes the login past a notice the GitHub CLI prints after it", %{opts: opts} do
      test_pid = self()

      record_calls(fn
        "gh", ["api", "user", "--jq", ".login"] ->
          {"octocat\n\nA new release of gh is available: 2.80.0 → 2.81.0\n", 0}

        "kubectl", args ->
          case step(args) do
            ["apply", "--server-side", "--force-conflicts", "-f", path] ->
              if String.ends_with?(path, "secret.json"),
                do: send(test_pid, {:secret, File.read!(path)})

              nil

            _other ->
              nil
          end

        _program, _args ->
          nil
      end)

      assert {:ok, _message} = Install.server(Keyword.put(opts, :username, nil))
      assert_received {:secret, contents}
      %{"items" => [_namespace, secret]} = Jason.decode!(contents)
      config = secret["data"][".dockerconfigjson"] |> Base.decode64!() |> Jason.decode!()
      assert config["auths"]["ghcr.io"]["username"] == "octocat"
    end

    test "refuses a digest that is not one", %{opts: opts} do
      for digest <- [nil, "latest", "sha256:abc", "sha256:" <> String.duplicate("AB", 32)] do
        assert {:error, message} = Install.server(Keyword.put(opts, :digest, digest))
        assert message =~ "digest"
      end
    end

    test "says to open the tunnel when there is no kubeconfig, or no address", %{
      opts: opts,
      dir: dir
    } do
      File.rm!(Path.join(dir, "tunnel.json"))
      assert {:error, message} = Install.server(opts)
      assert message =~ "mix ehos.server tunnel"

      File.rm!(Path.join(dir, "kubeconfig"))
      assert {:error, message} = Install.server(opts)
      assert message =~ "mix ehos.server tunnel"
    end

    test "takes the host it is given instead of the tunnel's address", %{opts: opts} do
      calls = record_calls()

      assert {:ok, message} = Install.server(Keyword.put(opts, :host, "ehos.example.org"))
      assert message =~ "https://ehos.example.org"

      {_helm, chart} =
        Enum.find(calls.(), &match?({"helm", ["upgrade", "--install", "ehos" | _]}, &1))

      assert "governance.host=ehos.example.org" in chart
    end

    test "rolls CoreDNS out by the rule's hash, the same for the same rule", %{opts: opts} do
      calls = record_calls()
      assert {:ok, _message} = Install.server(opts)
      assert {:ok, _message} = Install.server(opts)

      patches =
        for {"kubectl", args} <- calls.(),
            ["patch", "--type=merge", "-p", patch | _] <- [step(args)],
            do: Jason.decode!(patch)

      assert [same, same] = patches
      %{"spec" => %{"template" => %{"metadata" => %{"annotations" => annotations}}}} = same
      assert annotations["ehos.empowered.house/coredns-rule"] =~ ~r/\A[0-9a-f]{16}\z/
      refute Enum.any?(calls.(), fn {_p, args} -> "restart" in args end)
    end

    test "refuses a host or a name that is not a plain DNS name", %{opts: opts} do
      for host <- [
            "x.org' || name != '",
            "ehos.example.org,image.repository=evil",
            "sslip.io",
            "EHOS.example.org",
            "ehos.(.*).org",
            "10.0.0.5",
            "ehos.example.org\nkind: Secret"
          ] do
        assert {:error, message} = Install.server(Keyword.put(opts, :host, host))
        assert message =~ "--host"
      end

      for name <- ["../other", "Trial", "a,b", "trial\n"] do
        assert {:error, message} = Install.server(Keyword.put(opts, :name, name))
        assert message =~ "name"
      end
    end

    test "waits until a CA made before #218 is issued again excluding IP addresses, and says to trust the new one",
         %{opts: opts} do
      test_pid = self()
      {:ok, reads} = Agent.start_link(fn -> 0 end)

      calls =
        record_calls(fn
          "kubectl", args ->
            if match?(["get", "secret", "ehos-local-ca" | _], step(args)) do
              # Before the apply, and once after it, the CA is as it was; then it is issued again.
              case Agent.get_and_update(reads, &{&1, &1 + 1}) do
                read when read < 2 -> {Base.encode64(@names_only_pem), 0}
                _later -> {Base.encode64(@ca_pem), 0}
              end
            end

          _program, _args ->
            nil
        end)

      progress = fn line -> send(test_pid, {:progress, line}) end
      assert {:ok, _message} = Install.server(Keyword.put(opts, :progress, progress))

      messages = drain()
      lines = for {:progress, line} <- messages, do: line
      assert Enum.any?(lines, &(&1 =~ "issued again" and &1 =~ "Replace any copy"))

      # Renewed as `cmctl renew` does: its key and name stay, so what it signed still verifies.
      assert [patch] =
               for(
                 {"kubectl", args} <- calls.(),
                 ["patch", "certificate/ehos-local-ca" | rest] <- [step(args)],
                 do: rest
               )

      assert "--subresource=status" in patch

      [%{"type" => "Issuing", "status" => "True"}] =
        patch |> List.last() |> Jason.decode!() |> get_in(["status", "conditions"])
    end

    test "says so when the CA is not issued again within a minute", %{opts: opts} do
      record_calls(fn
        "kubectl", args ->
          if match?(["get", "secret", "ehos-local-ca" | _], step(args)),
            do: {Base.encode64(@names_only_pem), 0}

        _program, _args ->
          nil
      end)

      assert {:error, message} = Install.server(opts)
      assert message =~ "not issued again" and message =~ "kubectl describe certificate"
    end

    test "says to open the tunnel when the cluster does not answer", %{opts: opts} do
      record_calls(fn
        "kubectl", args ->
          if step(args) == ["get", "nodes", "-o", "name"],
            do: {"The connection to the server 127.0.0.1:16443 was refused", 1}

        _program, _args ->
          nil
      end)

      assert {:error, message} = Install.server(opts)
      assert message =~ "mix ehos.server tunnel"
    end
  end

  # Stubs every program with success, letting `override` answer first (nil to fall through), and
  # returns a function listing the calls made, in order.
  describe "prerequisites/1 (#220)" do
    setup do
      %{
        target: %Install{
          context: "k3d-ehos",
          host: "ehos.localhost",
          runner: CommandRunnerMock,
          source: @source
        }
      }
    end

    test "leaves a prerequisite deployed at its pinned version with its values as it is", %{
      target: target
    } do
      calls =
        record_calls(fn
          "helm", ["list", "--namespace", namespace, "--filter", "^" <> release | _] ->
            [prerequisite] =
              Enum.filter(
                Install.prerequisite_releases(),
                &(&1.namespace == namespace and "^#{&1.release}$" == "^" <> release)
              )

            {Jason.encode!([
               %{
                 "chart" => "#{prerequisite.name}-#{prerequisite.version}",
                 "status" => "deployed"
               }
             ]), 0}

          "helm", ["get", "values", release | _] ->
            prerequisite = Enum.find(Install.prerequisite_releases(), &(&1.release == release))
            {Jason.encode!(prerequisite.values), 0}

          _program, _args ->
            nil
        end)

      assert :ok = Install.prerequisites(target)
      refute Enum.any?(calls.(), &match?({"helm", ["upgrade" | _]}, &1))
    end

    test "installs one at another version, with other values, or not deployed", %{target: target} do
      calls =
        record_calls(fn
          "helm", ["list", "--namespace", "cnpg-system" | _] ->
            {~s([{"chart": "cloudnative-pg-0.28.0", "status": "deployed"}]), 0}

          "helm", ["list", "--namespace", "cert-manager", "--filter", "^cert-manager$" | _] ->
            {~s([{"chart": "cert-manager-v1.21.2", "status": "deployed"}]), 0}

          "helm", ["get", "values", "cert-manager" | _] ->
            {~s({"crds": {"enabled": true}}), 0}

          "helm", ["list" | _] ->
            {~s([{"chart": "trust-manager-v0.25.0", "status": "failed"}]), 0}

          _program, _args ->
            nil
        end)

      assert :ok = Install.prerequisites(target)

      upgraded = for {"helm", ["upgrade", "--install", release | _]} <- calls.(), do: release
      assert upgraded == ["cnpg", "cert-manager", "trust-manager"]
    end

    test "pulls CloudNativePG's chart by its digest, as the other two" do
      for release <- Install.prerequisite_releases() do
        assert release.chart =~ ~r/\Aoci:\/\/[a-z0-9.\/_-]+@sha256:[0-9a-f]{64}\z/, release.title
      end
    end
  end

  describe "chart/2 from a release" do
    # eh-os D-92: a release's chart is installed by the digest its release.json names, which Helm
    # checks; nothing is packaged.
    @tag evidence: "eh-os D-92"
    test "installs the chart by its digest, packaging nothing", %{tmp_dir: tmp_dir} do
      chart = "oci://ghcr.io/empoweredhouse/charts/ehos@sha256:" <> String.duplicate("1e", 32)
      calls = record_calls()

      target = %Install{
        context: "ehos-trial",
        host: @host,
        kubeconfig: "/k",
        runner: CommandRunnerMock,
        source: %Source{chart: {:oci, chart}, modules: tmp_dir}
      }

      assert :ok =
               Install.chart(target,
                 repository: "ghcr.io/empoweredhouse/ehos",
                 digest: @digest,
                 ca_file: Path.join(tmp_dir, "ca.crt")
               )

      refute Enum.any?(calls.(), &match?({"helm", ["package" | _]}, &1))

      assert Enum.any?(
               calls.(),
               &match?({"helm", ["upgrade", "--install", "ehos", ^chart | _]}, &1)
             )
    end
  end

  defp record_calls(override \\ fn _program, _args -> nil end)

  defp record_calls(opts) when is_list(opts) do
    pull? = Keyword.get(opts, :pull_credential, true)

    answer = if pull?, do: {"secret/ehos-pull-credential\n", 0}, else: {"NotFound", 1}

    record_calls(fn
      "kubectl", args ->
        if match?(["get", "secret", "ehos-pull-credential" | _], step(args)), do: answer

      _program, _args ->
        nil
    end)
  end

  defp record_calls(override) when is_function(override, 2) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    stub(CommandRunnerMock, :run, fn program, args ->
      Agent.update(agent, &[{program, args} | &1])

      case override.(program, args) do
        nil -> answer(program, args)
        result -> result
      end
    end)

    fn -> agent |> Agent.get(& &1) |> Enum.reverse() end
  end

  defp answer("kubectl", args) do
    case step(args) do
      ["get", "secret", "ehos-local-ca" | _] ->
        {"Warning: a line first\n" <> Base.encode64(@ca_pem), 0}

      _other ->
        {"", 0}
    end
  end

  defp answer("helm", ["package" | _]),
    do: {"Successfully packaged chart and saved it to: /tmp/x/ehos-0.1.0.tgz\n", 0}

  defp answer(_program, _args), do: {"", 0}

  # The arguments after the ones that point kubectl at the cluster.
  defp step(["--kubeconfig", _, "--context", _ | rest]), do: rest
  defp step(["--context", _ | rest]), do: rest
  defp step(args), do: args

  defp value_of(args, flag), do: args |> Enum.drop_while(&(&1 != flag)) |> Enum.at(1)

  defp drain(acc \\ []) do
    receive do
      message -> drain([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
