defmodule EhosPlatform.InstallTest do
  use ExUnit.Case, async: true

  import Hammox

  alias EhosPlatform.ClockMock
  alias EhosPlatform.CommandRunnerMock
  alias EhosPlatform.EnvMock
  alias EhosPlatform.Install
  alias EhosPlatform.Source

  doctest Install

  setup :verify_on_exit!

  @moduletag :tmp_dir

  @digest "sha256:" <> String.duplicate("ab", 32)
  # An eh-os checkout the commands are told about; every command is the mock's.
  @source Source.checkout("/src/eh-os")
  # Test CAs, certificates only, made with openssl: one whose name constraints permit @host alone and
  # exclude every IP address, as the installation's CA's do, and one constraining names alone, as
  # it did before.
  @ca_pem File.read!("test/support/fixtures/certificates/ca-excluding-ip.pem")
  @names_only_pem File.read!("test/support/fixtures/certificates/ca-names-only.pem")
  @example_org_pem File.read!("test/support/fixtures/certificates/ca-example-org.pem")
  # The installation's CA for another host, as it was before `--host` moved it (eh-os D-124).
  @other_host_pem File.read!("test/support/fixtures/certificates/ca-other-host.pem")
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

      # eh-os#828: an address's certificate in ehos-addresses, for the environment its label names.
      variables = Map.new(policy["spec"]["variables"], &{&1["name"], &1["expression"]})

      assert variables["environment"] =~
               "request.namespace == 'ehos-addresses' ? variables.labelled"
    end

    test "writes the CoreDNS rule for another host, and nothing broader" do
      rendered =
        "coredns-custom.yaml" |> Install.manifest() |> File.read!() |> Install.for_host(@host)

      %{"data" => %{"ehos.override" => rule}} = YamlElixir.read_from_string!(rendered)
      assert rule =~ ~S"^(.+\.)?ehos\.152-70-8-238\.sslip\.io\.$"
      refute rendered =~ "localhost"
    end
  end

  describe "external-names.yaml" do
    test "admits an ExternalName Service only in ehos-addresses and ehos-ingress, whoever asks" do
      documents =
        "external-names.yaml"
        |> Install.manifest()
        |> File.read!()
        |> YamlElixir.read_all_from_string!()

      [policy] = Enum.filter(documents, &(&1["kind"] == "ValidatingAdmissionPolicy"))
      [binding] = Enum.filter(documents, &(&1["kind"] == "ValidatingAdmissionPolicyBinding"))
      assert binding["spec"]["policyName"] == policy["metadata"]["name"]
      assert binding["spec"]["validationActions"] == ["Deny"]
      assert policy["spec"]["failurePolicy"] == "Fail"
      refute Map.has_key?(policy["spec"], "matchConditions")

      assert policy["spec"]["matchConstraints"] == %{
               "resourceRules" => [
                 %{
                   "apiGroups" => [""],
                   "apiVersions" => ["v1"],
                   "resources" => ["services"],
                   "operations" => ["CREATE", "UPDATE"]
                 }
               ]
             }

      [validation] = policy["spec"]["validations"]

      assert validation["expression"] ==
               "object.spec.?type.orValue('ClusterIP') != 'ExternalName' || " <>
                 "request.namespace in ['ehos-addresses', 'ehos-ingress']"
    end
  end

  describe "permits_only?/2" do
    test "tells a CA for the host from one for another host, or for names alone" do
      assert Install.permits_only?(@ca_pem, @host)
      refute Install.permits_only?(@other_host_pem, @host)
      refute Install.permits_only?(@names_only_pem, @host)
      refute Install.permits_only?("not a certificate", @host)
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
        env: EnvMock,
        clock: ClockMock
      ]

      # The environment holds nothing a test does not set, and nothing waits.
      stub(EnvMock, :get, fn _name -> nil end)
      stub(ClockMock, :sleep, fn _ms -> :ok end)

      %{opts: opts, dir: dir}
    end

    test "refuses the environment given as a map before it runs anything, and says none of it",
         %{opts: opts} do
      expect(CommandRunnerMock, :run, 0, fn _program, _args -> {"", 0} end)

      assert_raise ArgumentError,
                   ":env must name a module that implements EhosPlatform.Env",
                   fn ->
                     Install.server(Keyword.put(opts, :env, %{"GHCR_TOKEN" => "fixture-token"}))
                   end
    end

    # ehos-tools#543: Keyword.fetch!/2's KeyError would hold every option, the token among them.
    test "refuses a missing :source by its name before it runs anything, and holds none of the options",
         %{opts: opts} do
      expect(CommandRunnerMock, :run, 0, fn _program, _args -> {"", 0} end)

      error = assert_raise KeyError, fn -> Install.server(Keyword.delete(opts, :source)) end

      assert error == %KeyError{key: :source}
    end

    test "refuses :sleep, which :clock replaced, before it runs anything", %{opts: opts} do
      expect(CommandRunnerMock, :run, 0, fn _program, _args -> {"", 0} end)

      error =
        assert_raise ArgumentError, fn ->
          Install.server(Keyword.put(opts, :sleep, fn _ms -> :ok end))
        end

      assert Exception.message(error) ==
               ":sleep is no longer taken; give :clock, a module that implements EhosPlatform.Clock"
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
               {"kubectl", ["version", "-o", "json"]},
               {"kubectl", ["get", "crd", "helmcharts.helm.cattle.io"]},
               {"kubectl", ["apply", "--server-side", "--force-conflicts"]},
               {"kubectl", ["annotate", "secret", "ehos-pull-credential"]},
               {"kubectl", ["get", "crd", "helmcharts.helm.cattle.io"]},
               {"kubectl", ["apply", "-f", external_names]},
               {"kubectl", ["get", "services", "--all-namespaces"]},
               # eh-os#846: before Traefik, whose chart makes its Role there.
               {"kubectl", ["apply", "-f", addresses]},
               {"helm", ["list", "--namespace", "cnpg-system"]},
               {"helm", ["upgrade", "--install", "cnpg"]},
               {"helm", ["list", "--namespace", "cert-manager"]},
               {"helm", ["upgrade", "--install", "cert-manager"]},
               {"helm", ["list", "--namespace", "cert-manager"]},
               {"helm", ["upgrade", "--install", "trust-manager"]},
               {"helm", ["list", "--namespace", "ehos-ingress"]},
               {"helm", ["pull", traefik_chart, "--untar"]},
               {"kubectl", ["apply", "--server-side", "--field-manager=ehos-installer"]},
               {"helm", ["upgrade", "--install", "traefik"]},
               {"kubectl", ["get", "clusterrole,clusterrolebinding", "--selector"]},
               {"kubectl", ["auth", "can-i", "list"]},
               {"kubectl", ["auth", "can-i", "get"]},
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
               {"kubectl", ["get", "certificate", "ehos-governance-tls"]},
               {"helm", ["upgrade", "--install", "ehos"]},
               {"kubectl", ["wait", "--for=condition=Ready", "certificate/ehos-governance-tls"]}
             ] = steps

      assert traefik_chart =~ ~r/\Aoci:\/\/ghcr\.io\/traefik\/helm\/traefik@sha256:[0-9a-f]{64}\z/

      # The CA and the CoreDNS rule are rendered for the server's host, not applied as written.
      refute ca == Install.manifest("local-ca.yaml")
      refute coredns == Install.manifest("coredns-custom.yaml")
      assert Path.basename(external_names) == "external-names.yaml"
      assert Path.basename(addresses) == "addresses-namespace.yaml"

      {_helm, chart} =
        Enum.find(calls.(), &match?({"helm", ["upgrade", "--install", "ehos" | _]}, &1))

      assert "image.repository=ghcr.io/empoweredhouse/ehos" in chart
      assert "image.digest=#{@digest}" in chart
      assert "governance.host=#{@host}" in chart
      assert "environments.allowedImagePrefixes={ghcr.io/empoweredhouse/}" in chart

      # eh-os D-117: environments admit Traefik from where EHOS installs it, whatever the chart
      # says.
      assert "environments.ingressController.namespace=ehos-ingress" in chart
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

    # eh-os D-92: what runs, recorded for `upgrade` to read back.
    test "records what is installed in the release's values when told, and nothing otherwise", %{
      opts: opts
    } do
      installed = %{
        "version" => "0.17.0",
        "image" => "ghcr.io/empoweredhouse/ehos@#{@digest}",
        "chart" => "oci://ghcr.io/empoweredhouse/charts/ehos@#{@digest}"
      }

      for {given, expected} <- [{installed, [installed]}, {nil, []}] do
        calls = record_calls()
        assert {:ok, _message} = Install.server(Keyword.put(opts, :installed, given))

        {_helm, chart} =
          Enum.find(calls.(), &match?({"helm", ["upgrade", "--install", "ehos" | _]}, &1))

        # As JSON, which Helm reads whole: `--set` would split it on its commas.
        recorded =
          for ["--set-json", "installed=" <> json] <- Enum.chunk_every(chart, 2, 1),
              do: Jason.decode!(json)

        assert recorded == expected
      end
    end

    # eh-os#846: its Traefik would not serve an older EHOS's console; refused before anything runs.
    test "installs no EHOS before 0.17.0, running nothing", %{opts: opts} do
      calls = record_calls()
      old = %{"version" => "0.16.0", "image" => "i", "chart" => "c"}

      assert {:error, message} = Install.server(Keyword.put(opts, :installed, old))
      assert message =~ "Install 0.17.0 or later"
      assert calls.() == []
    end

    # eh-os D-113: as JSON, beside the installation's description; none given, the chart's defaults.
    test "gives the chart the sign-in limits when given, and none otherwise", %{opts: opts} do
      for {given, expected} <- [
            {%{"absolute" => "30d", "idle" => "14d"}, [%{"absolute" => "30d", "idle" => "14d"}]},
            {nil, []},
            {%{}, []}
          ] do
        calls = record_calls()
        assert {:ok, _message} = Install.server(Keyword.put(opts, :sign_in, given))

        {_helm, chart} =
          Enum.find(calls.(), &match?({"helm", ["upgrade", "--install", "ehos" | _]}, &1))

        written =
          for ["--set-json", "governance.signIn=" <> json] <- Enum.chunk_every(chart, 2, 1),
              do: Jason.decode!(json)

        assert written == expected
      end
    end

    # eh-os D-105: only when given; none leaves it to the chart (eh-os D-128 from EHOS 0.14.0).
    test "gives the chart four eyes when given, and nothing otherwise", %{opts: opts} do
      for {given, expected} <- [{false, [false]}, {true, [true]}, {nil, []}] do
        calls = record_calls()
        assert {:ok, _message} = Install.server(Keyword.put(opts, :four_eyes, given))

        {_helm, chart} =
          Enum.find(calls.(), &match?({"helm", ["upgrade", "--install", "ehos" | _]}, &1))

        written =
          for ["--set-json", "governance.promotion.fourEyes=" <> json] <-
                Enum.chunk_every(chart, 2, 1),
              do: Jason.decode!(json)

        assert written == expected
      end
    end

    # eh-os D-36: as JSON; the password's Secret named only where the server authenticates.
    test "gives the chart the SMTP server when given, and none otherwise", %{opts: opts} do
      with_user = %{
        "from" => "ehos@example.com",
        "smtp" => %{"host" => "smtp.example.com", "port" => 587, "username" => "ehos"}
      }

      without_user = %{"from" => "ehos@example.com", "smtp" => %{"host" => "mail", "port" => 25}}
      empty_user = put_in(without_user, ["smtp", "username"], "")

      for {given, expected} <- [
            {with_user,
             [
               put_in(with_user, ["smtp", "password"], %{
                 "secretName" => "ehos-smtp",
                 "secretKey" => "password"
               })
             ]},
            {without_user, [without_user]},
            # The chart refuses a password's Secret without a user, after the Secrets are written.
            {empty_user, [empty_user]},
            {nil, []}
          ] do
        calls = record_calls()
        assert {:ok, _message} = Install.server(Keyword.put(opts, :mail, given))

        {_helm, chart} =
          Enum.find(calls.(), &match?({"helm", ["upgrade", "--install", "ehos" | _]}, &1))

        written =
          for ["--set-json", "governance.mail=" <> json] <- Enum.chunk_every(chart, 2, 1),
              do: Jason.decode!(json)

        assert written == expected
      end
    end

    test "writes the SMTP password from a file only this user reads, never from an argument",
         %{opts: opts} do
      test_pid = self()
      password = "s3cret pass"

      calls =
        record_calls(fn
          "kubectl", args ->
            with ["apply", "--server-side", "--force-conflicts", "-f", path] <- step(args),
                 true <- File.exists?(path),
                 %{"items" => [_namespace, %{"metadata" => %{"name" => "ehos-smtp"}} = secret]} <-
                   path |> File.read!() |> Jason.decode!() do
              send(test_pid, {:smtp, secret, File.stat!(path).mode, path})
            end

            nil

          _program, _args ->
            nil
        end)

      mail = %{"from" => "a@b.cd", "smtp" => %{"host" => "h", "port" => 587, "username" => "u"}}

      assert {:ok, _message} =
               opts
               |> Keyword.put(:mail, mail)
               |> Keyword.put(:smtp_password, password)
               |> Install.server()

      assert_received {:smtp, secret, mode, path}
      assert Bitwise.band(mode, 0o777) == 0o600
      refute File.exists?(path)
      assert secret["type"] == "Opaque"

      assert secret["metadata"] == %{
               "name" => "ehos-smtp",
               "namespace" => "ehos-system",
               "annotations" => %{"ehos.empowered.house/restart" => "pending"}
             }

      assert Base.decode64!(secret["data"]["password"]) == password

      for {_program, args} <- calls.(), arg <- args do
        refute arg =~ password
        refute arg =~ Base.encode64(password)
      end
    end

    test "keeps the password out of what a failed apply printed", %{opts: opts} do
      password = "s3cret"

      record_calls(fn
        "kubectl", args ->
          with ["apply", "--server-side", "--force-conflicts", "-f", path] <- step(args),
               true <- File.read!(path) =~ "ehos-smtp" do
            {"error: rejected #{password} (#{Base.encode64(password)})", 1}
          else
            _other -> nil
          end

        _program, _args ->
          nil
      end)

      mail = %{"from" => "a@b.cd", "smtp" => %{"host" => "h", "port" => 587, "username" => "u"}}

      assert {:error, message} =
               opts
               |> Keyword.put(:mail, mail)
               |> Keyword.put(:smtp_password, password)
               |> Install.server()

      refute message =~ password
      refute message =~ Base.encode64(password)
      assert message =~ "[the password]"
    end

    test "keeps the SMTP password the cluster holds, and refuses a user with none", %{opts: opts} do
      mail = %{"from" => "a@b.cd", "smtp" => %{"host" => "h", "port" => 587, "username" => "u"}}
      opts = Keyword.put(opts, :mail, mail)

      for {answer, outcome} <- [
            {{"secret/ehos-smtp\n", 0}, :ok},
            {{~s|Error from server (NotFound): secrets "ehos-smtp" not found|, 1}, :refused},
            # A cluster EHOS was never installed in holds no password either (#300).
            {{~s|Error from server (NotFound): namespaces "ehos-system" not found|, 1}, :refused}
          ] do
        test_pid = self()

        calls =
          record_calls(fn
            "kubectl", args ->
              case step(args) do
                ["get", "secret", "ehos-smtp" | _] ->
                  answer

                ["apply", "--server-side", "--force-conflicts", "-f", path] ->
                  if File.read!(path) =~ "ehos-smtp", do: send(test_pid, {:smtp_written})
                  nil

                _other ->
                  nil
              end

            _program, _args ->
              nil
          end)

        case outcome do
          :ok ->
            assert {:ok, _message} = Install.server(opts)

            # Kept as it is: nothing written over it, and nothing restarted for it.
            refute_received {:smtp_written}

            refute Enum.any?(calls.(), fn {program, args} ->
                     program == "kubectl" and match?(["rollout", "restart" | _], step(args))
                   end)

          :refused ->
            assert {:error, message} = Install.server(opts)
            assert message =~ "set SMTP_PASSWORD"
            refute Enum.any?(calls.(), &match?({"helm", ["upgrade" | _]}, &1))

            refute Enum.any?(calls.(), fn {program, args} ->
                     program == "kubectl" and "apply" in args
                   end)
        end
      end
    end

    # A password given again is not a new one; a restart a failed run left owing is made on the
    # next, and only then unmarked.
    test "restarts for a password only when it changed, or when a run before did not", %{
      opts: opts
    } do
      mail = %{"from" => "a@b.cd", "smtp" => %{"host" => "h", "port" => 587, "username" => "u"}}
      test_pid = self()

      for {given, held, pending, written?, restarted?} <- [
            {"same", Base.encode64("same"), "", false, false},
            {"new", Base.encode64("old"), "", true, true},
            {nil, nil, "pending", false, true},
            {"same", Base.encode64("same"), "pending", false, true}
          ] do
        calls =
          record_calls(fn
            "kubectl", args ->
              case step(args) do
                [
                  "get",
                  "secret",
                  "ehos-smtp",
                  "-n",
                  "ehos-system",
                  "-o",
                  "jsonpath={.data.password}"
                ] ->
                  {"#{held}", 0}

                [
                  "get",
                  "secret",
                  "ehos-smtp",
                  "-n",
                  "ehos-system",
                  "-o",
                  "jsonpath={.metadata" <> _
                ] ->
                  {pending, 0}

                ["apply", "--server-side", "--force-conflicts", "-f", path] ->
                  if File.read!(path) =~ "ehos-smtp", do: send(test_pid, {:smtp_written})
                  nil

                _other ->
                  nil
              end

            _program, _args ->
              nil
          end)

        assert {:ok, _message} =
                 opts
                 |> Keyword.put(:mail, mail)
                 |> Keyword.put(:smtp_password, given)
                 |> Install.server()

        steps = Enum.map(calls.(), fn {program, args} -> {program, step(args)} end)

        assert Enum.any?(steps, &match?({"kubectl", ["rollout", "restart" | _]}, &1)) ==
                 restarted?

        assert Enum.member?(
                 steps,
                 {"kubectl",
                  [
                    "annotate",
                    "secret",
                    "ehos-smtp",
                    "-n",
                    "ehos-system",
                    "ehos.empowered.house/restart-"
                  ]}
               ) == restarted?

        if written?, do: assert_received({:smtp_written}), else: refute_received({:smtp_written})
      end
    end

    # What runs is recorded before the restart: one that fails leaves the record true, and the
    # Secret marked for the next run.
    test "records what runs before it restarts for a password", %{opts: opts, dir: dir} do
      mail = %{"from" => "a@b.cd", "smtp" => %{"host" => "h", "port" => 587, "username" => "u"}}

      record_calls(fn
        "kubectl", args ->
          if match?(["rollout", "status", "deployment/ehos-governance" | _], step(args)),
            do: {"error: timed out waiting for the condition", 1}

        _program, _args ->
          nil
      end)

      assert {:error, message} =
               opts
               |> Keyword.put(:mail, mail)
               |> Keyword.put(:smtp_password, "new")
               |> Install.server()

      assert message =~ "timed out"

      assert dir
             |> Path.join("install.json")
             |> File.read!()
             |> Jason.decode!()
             |> Map.get("digest") == @digest
    end

    test "refuses a password with no user to give it to", %{opts: opts} do
      calls = record_calls()
      mail = %{"from" => "a@b.cd", "smtp" => %{"host" => "h", "port" => 587}}

      assert {:error, message} =
               opts
               |> Keyword.put(:mail, mail)
               |> Keyword.put(:smtp_password, "p")
               |> Install.server()

      assert message =~ "no SMTP user is"
      refute Enum.any?(calls.(), &match?({"helm", ["upgrade" | _]}, &1))
      # Before anything changes, the pull credential included.
      refute Enum.any?(calls.(), fn {program, args} ->
               program == "kubectl" and "apply" in args
             end)
    end

    # The chart gives the password as a variable, read when the pod starts: a rotated one reaches
    # EHOS only through a restart, and one kept needs none.
    test "restarts the governance plane after it writes a password, and only then", %{opts: opts} do
      mail = %{"from" => "a@b.cd", "smtp" => %{"host" => "h", "port" => 587, "username" => "u"}}

      for {password, restarted?} <- [{"new", true}, {nil, false}] do
        calls = record_calls()

        assert {:ok, _message} =
                 opts
                 |> Keyword.put(:mail, mail)
                 |> Keyword.put(:smtp_password, password)
                 |> Install.server()

        steps = Enum.map(calls.(), fn {program, args} -> {program, step(args)} end)

        restart =
          {"kubectl", ["rollout", "restart", "deployment/ehos-governance", "-n", "ehos-system"]}

        assert Enum.member?(steps, restart) == restarted?

        if restarted? do
          upgrade = Enum.find_index(steps, &match?({"helm", ["upgrade" | _]}, &1))
          restart_at = Enum.find_index(steps, &(&1 == restart))
          assert restart_at > upgrade

          status_at =
            Enum.find_index(
              steps,
              &match?({"kubectl", ["rollout", "status", "deployment/ehos-governance" | _]}, &1)
            )

          assert status_at > restart_at

          assert Enum.any?(
                   steps,
                   &match?(
                     {"kubectl", ["rollout", "status", "deployment/ehos-governance" | _]},
                     &1
                   )
                 )
        end
      end
    end

    # eh-os D-117: the chart makes the console's Certificate since; one cert-manager made for the
    # console's Ingress is handed to the release first, or Helm refuses to take it over. Only when
    # the chart being installed makes it: a chart from before still asks for it by the Ingress.
    # Its keys in another order, and the name quoted: read as YAML, not as a layout.
    @chart_with_certificate """
    ---
    # Source: ehos/templates/governance.yaml
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      labels:
        app.kubernetes.io/component: governance
      namespace: ehos-system
      name: "ehos-governance-tls"
    """

    @chart_without_certificate """
    ---
    # Source: ehos/templates/data-ca.yaml
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: ehos-data-ca
    ---
    # Source: ehos/templates/governance.yaml
    apiVersion: networking.k8s.io/v1
    kind: Ingress
    metadata:
      name: ehos-governance-tls
    """

    # The Certificate's managed fields as cert-manager's ingress-shim leaves them, an update, beside
    # an update of k3s's.
    @shim_fields [
      %{
        "manager" => "cert-manager-ingress-shim",
        "operation" => "Update",
        "apiVersion" => "cert-manager.io/v1",
        "fieldsType" => "FieldsV1",
        "fieldsV1" => %{"f:metadata" => %{"f:labels" => %{"f:helm.sh/chart" => %{}}}}
      },
      %{
        "manager" => "k3s",
        "operation" => "Update",
        "fieldsType" => "FieldsV1",
        "fieldsV1" => %{}
      }
    ]

    # The shim's fields stay on a Certificate an Ingress owns; one the chart made has Helm's alone.
    defp console_certificate(made_by, chart, fields \\ nil) do
      fields =
        fields ||
          if("Ingress" in String.split(made_by),
            do: @shim_fields,
            else: [%{"manager" => "helm", "operation" => "Apply"}]
          )

      record_calls(fn
        "kubectl", args ->
          case step(args) do
            [
              "get",
              "certificate",
              "ehos-governance-tls",
              "-n",
              "ehos-system",
              "--show-managed-fields" | _
            ] ->
              {"42 " <> Jason.encode!(fields), 0}

            ["get", "certificate", "ehos-governance-tls" | _] ->
              {"Warning: first\nehos-governance-tls=#{made_by}\n", 0}

            _other ->
              nil
          end

        "helm", ["template", "ehos" | _] ->
          {chart, 0}

        _program, _args ->
          nil
      end)
    end

    defp patched?(calls),
      do:
        Enum.any?(calls.(), fn {_program, args} ->
          match?(["patch", "certificate" | _], step(args))
        end)

    test "hands a console Certificate cert-manager made for the Ingress over to a chart that makes it, first",
         %{opts: opts} do
      calls = console_certificate("Ingress", @chart_with_certificate)

      assert {:ok, _message} = Install.server(opts)

      steps = Enum.map(calls.(), fn {program, args} -> {program, step(args)} end)

      assert {"kubectl",
              [
                "get",
                "certificate",
                "ehos-governance-tls",
                "-n",
                "ehos-system",
                "--ignore-not-found",
                "-o",
                "jsonpath={.metadata.name}={.metadata.ownerReferences[*].kind}"
              ]} in steps

      patch_at = Enum.find_index(steps, &match?({"kubectl", ["patch", "certificate" | _]}, &1))

      chart_at =
        Enum.find_index(steps, &match?({"helm", ["upgrade", "--install", "ehos" | _]}, &1))

      assert patch_at < chart_at

      # The package installed, rendered with the values it is installed with.
      {"helm", ["template", "ehos", package, "--namespace", "ehos-system" | rendered]} =
        Enum.find(steps, &match?({"helm", ["template" | _]}, &1))

      {"helm", ["upgrade", "--install", "ehos", ^package | installed]} = Enum.at(steps, chart_at)
      assert "image.digest=#{@digest}" in rendered
      # Every value, in the order the install passes them.
      assert installed
             |> Enum.chunk_every(length(rendered), 1, :discard)
             |> Enum.member?(rendered)

      {"kubectl",
       [
         "patch",
         "certificate",
         "ehos-governance-tls",
         "-n",
         "ehos-system",
         "--type=merge",
         "-p",
         patch
       ]} =
        Enum.at(steps, patch_at)

      # Then Helm 4, applying as `helm`, is given the fields the ingress-shim applied.
      {"kubectl",
       [
         "patch",
         "certificate",
         "ehos-governance-tls",
         "-n",
         "ehos-system",
         "--type=json",
         "-p",
         fields
       ]} =
        Enum.find(
          steps,
          &match?({"kubectl", ["patch", "certificate", _, _, _, "--type=json" | _]}, &1)
        )

      assert [
               %{"op" => "test", "path" => "/metadata/resourceVersion", "value" => "42"},
               %{"op" => "replace", "path" => "/metadata/managedFields", "value" => renamed}
             ] = Jason.decode!(fields)

      # An apply of Helm's: renamed alone, an update stays another owner to server-side apply.
      assert Enum.map(renamed, &{&1["manager"], &1["operation"]}) == [
               {"helm", "Apply"},
               {"k3s", "Update"}
             ]

      assert hd(renamed)["fieldsV1"] == hd(@shim_fields)["fieldsV1"]
      assert hd(renamed)["apiVersion"] == "cert-manager.io/v1"

      assert Jason.decode!(patch) == %{
               "metadata" => %{
                 "ownerReferences" => nil,
                 "labels" => %{"app.kubernetes.io/managed-by" => "Helm"},
                 "annotations" => %{
                   "meta.helm.sh/release-name" => "ehos",
                   "meta.helm.sh/release-namespace" => "ehos-system"
                 }
               }
             }
    end

    # A run that freed it from the Ingress and stopped before Helm took its fields over.
    test "gives Helm the shim's fields of one handed over before, whatever the chart", %{
      opts: opts
    } do
      calls = console_certificate("", @chart_without_certificate, @shim_fields)
      assert {:ok, _message} = Install.server(opts)

      assert Enum.any?(calls.(), fn {_program, args} ->
               match?(["patch", "certificate", _, _, _, "--type=json" | _], step(args))
             end)

      refute Enum.any?(calls.(), &match?({"helm", ["template" | _]}, &1))
    end

    # Helm applied fields the shim shares with it, with the same values, so without a conflict.
    test "joins the shim's fields to an apply Helm made already", %{opts: opts} do
      helms = %{
        "manager" => "helm",
        "operation" => "Apply",
        "apiVersion" => "cert-manager.io/v2",
        "fieldsType" => "FieldsV1",
        "fieldsV1" => %{"f:metadata" => %{"f:labels" => %{"f:app.kubernetes.io/name" => %{}}}}
      }

      calls = console_certificate("", @chart_with_certificate, @shim_fields ++ [helms])
      assert {:ok, _message} = Install.server(opts)

      {"kubectl", args} =
        Enum.find(calls.(), fn {_program, args} ->
          match?(["patch", "certificate", _, _, _, "--type=json" | _], step(args))
        end)

      [_test, %{"value" => renamed}] = args |> step() |> List.last() |> Jason.decode!()

      assert [
               %{
                 "manager" => "helm",
                 "operation" => "Apply",
                 # The version Helm applies in.
                 "apiVersion" => "cert-manager.io/v2",
                 "fieldsV1" => %{
                   "f:metadata" => %{
                     "f:labels" => %{"f:helm.sh/chart" => %{}, "f:app.kubernetes.io/name" => %{}}
                   }
                 }
               },
               %{"manager" => "k3s"}
             ] = renamed
    end

    # 0.5.2 renamed the shim's update `helm`'s, which server-side apply still counts as another
    # owner than Helm's apply.
    test "makes an update of Helm's, as 0.5.2 left it, Helm's apply", %{opts: opts} do
      left = [%{hd(@shim_fields) | "manager" => "helm"} | tl(@shim_fields)]
      calls = console_certificate("", @chart_without_certificate, left)
      assert {:ok, _message} = Install.server(opts)

      {"kubectl", args} =
        Enum.find(calls.(), fn {_program, args} ->
          match?(["patch", "certificate", _, _, _, "--type=json" | _], step(args))
        end)

      [_test, %{"value" => renamed}] = args |> step() |> List.last() |> Jason.decode!()

      assert Enum.map(renamed, &{&1["manager"], &1["operation"]}) == [
               {"helm", "Apply"},
               {"k3s", "Update"}
             ]

      assert hd(renamed)["fieldsV1"] == hd(@shim_fields)["fieldsV1"]
      assert hd(renamed)["apiVersion"] == "cert-manager.io/v1"
    end

    test "hands it over among other owners, and leaves one no Ingress owns", %{opts: opts} do
      calls = console_certificate("Certificate Ingress", @chart_with_certificate)
      assert {:ok, _message} = Install.server(opts)
      assert patched?(calls)

      calls = console_certificate("Certificate", @chart_with_certificate)
      assert {:ok, _message} = Install.server(opts)
      refute patched?(calls)
      refute Enum.any?(calls.(), &match?({"helm", ["template" | _]}, &1))
    end

    test "leaves it with the Ingress when the chart being installed is one from before", %{
      opts: opts
    } do
      calls = console_certificate("Ingress", @chart_without_certificate)
      assert {:ok, _message} = Install.server(opts)
      refute patched?(calls)
    end

    test "leaves a console Certificate the chart made alone, without rendering the chart", %{
      opts: opts
    } do
      calls = console_certificate("", @chart_with_certificate)
      assert {:ok, _message} = Install.server(opts)
      refute patched?(calls)
      refute Enum.any?(calls.(), &match?({"helm", ["template" | _]}, &1))
    end

    test "installs nothing when the console's Certificate cannot be read", %{opts: opts} do
      calls =
        record_calls(fn
          "kubectl", args ->
            if match?(["get", "certificate" | _], step(args)),
              do: {"The connection to the server was refused", 1}

          _program, _args ->
            nil
        end)

      assert {:error, _message} = Install.server(opts)
      refute Enum.any?(calls.(), &match?({"helm", ["upgrade", "--install", "ehos" | _]}, &1))
    end

    test "installs nothing when the chart cannot be rendered", %{opts: opts} do
      calls =
        record_calls(fn
          "kubectl", args ->
            if match?(["get", "certificate" | _], step(args)),
              do: {"ehos-governance-tls=Ingress", 0}

          "helm", ["template", "ehos" | _] ->
            {"Error: template: ehos/templates/governance.yaml: required value", 1}

          _program, _args ->
            nil
        end)

      assert {:error, _message} = Install.server(opts)
      refute Enum.any?(calls.(), &match?({"helm", ["upgrade", "--install", "ehos" | _]}, &1))
    end

    test "installs nothing when the console's Certificate cannot be handed over", %{opts: opts} do
      calls =
        record_calls(fn
          "kubectl", args ->
            case step(args) do
              ["get", "certificate", "ehos-governance-tls" | _] ->
                {"ehos-governance-tls=Ingress", 0}

              ["patch", "certificate" | _] ->
                {"Error from server (Forbidden)", 1}

              _other ->
                nil
            end

          "helm", ["template", "ehos" | _] ->
            {@chart_with_certificate, 0}

          _program, _args ->
            nil
        end)

      assert {:error, _message} = Install.server(opts)
      refute Enum.any?(calls.(), &match?({"helm", ["upgrade", "--install", "ehos" | _]}, &1))
    end

    # eh-os D-117: EHOS installs its own Traefik; one k3s bundles would contend with it for the
    # ports 80 and 443.
    defp bundled_traefik(crd, helmchart) do
      record_calls(fn
        "kubectl", args ->
          case step(args) do
            ["get", "crd", "helmcharts.helm.cattle.io" | _] ->
              {crd, 0}

            ["get", "helmchart", "traefik", "traefik-crd", "-n", "kube-system" | _] ->
              {helmchart, 0}

            _other ->
              nil
          end

        _program, _args ->
          nil
      end)
    end

    # eh-os#823: a server made before EHOS installed its own Traefik, switched. k3s's Traefik, its
    # HelmCharts and its CRDs, are installed until the server has been switched over SSH; the
    # first ask after finds the API server restarting, and they are gone after `gone_after` more.
    defp server_with_bundled_traefik(
           dir,
           opts,
           ssh,
           gone_after,
           bundled \\ "traefik traefik-crd",
           crds_after \\ 0
         ) do
      File.write!(Path.join(dir, "server.tfvars.json"), "{}")
      File.write!(Path.join(dir, "installation.json"), ~s({"provider": "oci"}))
      Process.put(:switched, false)
      Process.put(:asked_after, 0)

      calls =
        record_calls(fn
          "ssh", args ->
            Process.put(:switched, true)
            ssh.(args)

          "kubectl", args ->
            switching_kubectl(step(args), gone_after, crds_after, bundled)

          _program, _args ->
            nil
        end)

      {opts
       |> Keyword.put(:passphrase, String.duplicate("p", 16))
       |> Keyword.put(:switch_traefik, true), calls}
    end

    defp switching_kubectl(
           ["get", "crd", "helmcharts.helm.cattle.io" | _],
           _gone,
           _crds,
           _bundled
         ),
         do: {"customresourcedefinition.apiextensions.k8s.io/helmcharts.helm.cattle.io", 0}

    defp switching_kubectl(
           ["get", "helmchart", "traefik", "traefik-crd" | _],
           gone_after,
           _crds,
           bundled
         ) do
      gone_after
      |> bundled_until(bundled)
      |> tap(fn _answer -> Process.put(:asked, (Process.get(:asked) || 0) + 1) end)
    end

    # The CRDs may outlast the HelmCharts, by `crds_after` asks.
    defp switching_kubectl(
           ["get", "crd", "--request-timeout=10s", "-o", "jsonpath=" <> _],
           gone_after,
           crds_after,
           _bundled
         ) do
      if Process.get(:asked_after) > gone_after + crds_after,
        do: {"", 0},
        else: {"ingressroutes.traefik.io middlewares.traefik.io ", 0}
    end

    defp switching_kubectl(_other, _gone, _crds, _bundled), do: nil

    defp bundled_until(gone_after, bundled) do
      if Process.get(:switched) do
        asked = Process.put(:asked_after, Process.get(:asked_after) + 1) + 1

        cond do
          asked == 1 -> {"The connection to the server 127.0.0.1:16443 was refused", 1}
          asked > gone_after -> {"", 0}
          true -> {bundled, 0}
        end
      else
        {"Warning: first\n" <> bundled, 0}
      end
    end

    defp writes?(steps),
      do:
        Enum.any?(steps, fn {program, args} ->
          program == "helm" or match?(["apply" | _], args)
        end)

    test "switches a server that runs k3s's Traefik to EHOS's, then installs", %{
      opts: opts,
      dir: dir
    } do
      test = self()

      {opts, calls} =
        server_with_bundled_traefik(
          dir,
          opts,
          fn args ->
            send(test, {:ssh, args})
            {"", 0}
          end,
          3
        )

      assert {:ok, _message} =
               Install.server(Keyword.put(opts, :progress, &send(test, {:progress, &1})))

      # At the tunnel's address, k3s's configuration given a drop-in that adds to its `disable`
      # list, and k3s restarted, not waited for: the cluster is asked instead.
      assert_received {:ssh, args}
      assert "ubuntu@152.70.8.238" in args
      command = List.last(args)
      assert command =~ ~r/\Asudo -n sh -c '/
      assert command =~ "/etc/rancher/k3s/config.yaml.d/ehos-traefik.yaml"
      assert command =~ ~s(disable+:\\n  - traefik\\n)
      assert command =~ "systemctl restart --no-block k3s"
      refute command =~ "/etc/rancher/k3s/config.yaml;"

      assert_received {:progress, "Switching the server from k3s's Traefik to EHOS's" <> _}
      assert_received {:progress, "k3s's Traefik is gone from the server"}

      # What could still refuse came first; EHOS's Traefik and the chart only after.
      steps = Enum.map(calls.(), fn {program, args} -> {program, step(args)} end)
      ssh_at = Enum.find_index(steps, &match?({"ssh", _}, &1))
      {before, after_switch} = Enum.split(steps, ssh_at)
      assert Enum.any?(before, &match?({"kubectl", ["apply", "--server-side" | _]}, &1))
      refute Enum.any?(before, &match?({"helm", _}, &1))

      assert Enum.any?(
               after_switch,
               &match?({"helm", ["upgrade", "--install", "traefik" | _]}, &1)
             )

      assert Enum.any?(after_switch, &match?({"helm", ["upgrade", "--install", "ehos" | _]}, &1))
    end

    test "switches a server where the HelmChart of k3s's Traefik's CRDs alone is left", %{
      opts: opts,
      dir: dir
    } do
      {opts, calls} =
        server_with_bundled_traefik(dir, opts, fn _args -> {"", 0} end, 2, "traefik-crd")

      assert {:ok, _message} = Install.server(opts)
      assert Enum.any?(calls.(), &match?({"ssh", _}, &1))
    end

    test "waits for the CRDs to be gone too, not the HelmCharts alone", %{opts: opts, dir: dir} do
      Process.put(:asked, 0)

      {opts, calls} =
        server_with_bundled_traefik(
          dir,
          opts,
          fn _args -> {"", 0} end,
          2,
          "traefik traefik-crd",
          3
        )

      assert {:ok, _message} = Install.server(opts)
      # Asked once before the switch; after it, until the HelmCharts went (the API restarting,
      # then twice), then three more times for the CRDs; then once by the prerequisites.
      assert Process.get(:asked) == 1 + 3 + 3 + 1
      assert Enum.any?(calls.(), &match?({"helm", ["upgrade", "--install", "traefik" | _]}, &1))
    end

    test "refuses, writing nothing, to switch a server unless told to", %{opts: opts, dir: dir} do
      {opts, calls} = server_with_bundled_traefik(dir, opts, fn _args -> {"", 0} end, 0)

      assert {:error, message} = Install.server(Keyword.delete(opts, :switch_traefik))
      assert message =~ "runs k3s's Traefik (HelmCharts traefik traefik-crd in kube-system)"
      assert message =~ "down for a few minutes"
      assert message =~ "--switch-traefik"
      steps = Enum.map(calls.(), fn {program, args} -> {program, step(args)} end)
      refute writes?(steps)
      refute Enum.any?(steps, &match?({"ssh", _}, &1))
    end

    test "installs nothing when the switch fails, or k3s's Traefik stays", %{opts: opts, dir: dir} do
      for {ssh, gone_after, said} <- [
            {fn _args -> {"sudo: a password is required", 1} end, 0, "exit status 1"},
            {fn _args -> {"", 0} end, 1_000, "not gone after 60 checks, 5 s apart"}
          ] do
        {opts, calls} = server_with_bundled_traefik(dir, opts, ssh, gone_after)

        assert {:error, message} = Install.server(opts)
        assert message =~ said
        assert message =~ "--switch-traefik"
        refute Enum.any?(calls.(), &match?({"helm", _}, &1))
      end
    end

    test "says why the server cannot be reached for the switch", %{opts: opts, dir: dir} do
      {opts, calls} = server_with_bundled_traefik(dir, opts, fn _args -> {"", 0} end, 0)

      assert {:error, message} = Install.server(Keyword.put(opts, :passphrase, "short"))
      assert message =~ "EHOS_STATE_PASSPHRASE"
      assert message =~ "Nothing was changed."
      refute writes?(Enum.map(calls.(), fn {program, args} -> {program, step(args)} end))

      # The console's host given, so the record's address is needed for the switch alone.
      File.write!(Path.join(dir, "tunnel.json"), ~s({"port":16443}))
      assert {:error, message} = Install.server(Keyword.put(opts, :host, "ehos.example.com"))
      assert message =~ "names no server address"
    end

    test "installs on a k3s cluster made without it, and on a cluster that is not k3s", %{
      opts: opts
    } do
      calls =
        bundled_traefik(
          "customresourcedefinition.apiextensions.k8s.io/helmcharts.helm.cattle.io",
          ""
        )

      assert {:ok, _message} = Install.server(opts)
      assert Enum.any?(calls.(), &match?({"helm", ["upgrade", "--install", "traefik" | _]}, &1))

      calls = bundled_traefik("", "")
      assert {:ok, _message} = Install.server(opts)

      refute Enum.any?(calls.(), fn {program, args} ->
               program == "kubectl" and match?(["get", "helmchart" | _], step(args))
             end)
    end

    test "installs Traefik in ehos-ingress from the chart pulled by digest, its CRDs applied first",
         %{opts: opts} do
      calls = record_calls()
      assert {:ok, _message} = Install.server(opts)
      steps = Enum.map(calls.(), fn {program, args} -> {program, step(args)} end)

      [traefik] = Enum.filter(Install.prerequisite_releases(), &(&1.release == "traefik"))

      pull_at =
        Enum.find_index(
          steps,
          &match?({"helm", ["pull", chart, "--untar" | _]} when chart == traefik.chart, &1)
        )

      {"helm", ["pull", _chart, "--untar", "--untardir", dir | _]} = Enum.at(steps, pull_at)

      # Traefik's CRDs, not Traefik Hub's, and none taken from a manager that holds them otherwise.
      {"kubectl", ["apply", "--server-side", "--field-manager=ehos-installer" | files]} =
        Enum.at(steps, pull_at + 1)

      assert files == [
               "-f",
               Path.join(dir, "traefik/crds/traefik.io_ingressroutes.yaml"),
               "-f",
               Path.join(dir, "traefik/crds/traefik.io_middlewares.yaml")
             ]

      {"helm", ["upgrade", "--install", "traefik", chart | args]} = Enum.at(steps, pull_at + 2)
      assert chart == Path.join(dir, "traefik")
      assert value_of(args, "--namespace") == "ehos-ingress"
      assert "--skip-crds" in args

      set = for {"--set", value} <- Enum.zip(args, tl(args)), do: value
      assert "service.spec.externalTrafficPolicy=Local" in set
      assert "api.dashboard=false" in set
      assert "providers.kubernetesIngress.allowExternalNameServices=true" in set
      assert "providers.kubernetesCRD.allowExternalNameServices=true" in set
      # A route names only a Service of its own namespace, the console's `ExternalName` too.
      refute Enum.any?(set, &(&1 =~ ~r/allowCrossNamespace/))
      # eh-os#846: Roles in its two namespaces, never a ClusterRole, and no IngressClass.
      assert "rbac.namespaced=true" in set
      assert "ingressClass.enabled=false" in set
      assert "providers.kubernetesIngress.namespaces={ehos-addresses,ehos-ingress}" in set
      assert "providers.kubernetesCRD.crossProviderNamespaces={ehos-ingress}" in set
      refute Enum.any?(set, &(&1 =~ ~r/kubernetesCRD\.namespaces/))
      assert "priorityClassName=system-cluster-critical" in set
      assert Enum.any?(set, &(&1 =~ ~r/\Aimage\.tag=v3\.7\.15@sha256:[0-9a-f]{64}\z/))
    end

    test "installs no Traefik when its chart cannot be pulled, or its CRDs not applied", %{
      opts: opts
    } do
      for failing <- [:pull, :crds] do
        calls =
          record_calls(fn
            "helm", ["pull", "oci://ghcr.io/traefik/" <> _ | _] when failing == :pull ->
              {"Error: GET \"https://ghcr.io/v2/traefik/helm/traefik\": 502", 1}

            "kubectl", args ->
              if failing == :crds and
                   match?(
                     ["apply", "--server-side", "--field-manager=ehos-installer" | _],
                     step(args)
                   ),
                 do: {"error: Apply failed with 1 conflict: conflict with \"helm\"", 1}

            _program, _args ->
              nil
          end)

        assert {:error, _message} = Install.server(opts), inspect(failing)
        refute Enum.any?(calls.(), &match?({"helm", ["upgrade", "--install", "traefik" | _]}, &1))
        refute Enum.any?(calls.(), &match?({"helm", ["upgrade", "--install", "ehos" | _]}, &1))
      end
    end

    test "pulls a release's chart with the registry credential, in a file only this user reads " <>
           "for the pull alone, and installs it from here",
         %{opts: opts} do
      test_pid = self()
      chart = "oci://ghcr.io/empoweredhouse/charts/ehos@" <> @digest
      opts = Keyword.put(opts, :source, %EhosPlatform.Source{chart: {:oci, chart}, modules: nil})

      calls =
        record_calls(fn
          "helm", ["pull", ^chart, "--destination", _destination | args] = all ->
            path = value_of(args, "--registry-config")
            send(test_pid, {:registry, path, File.read!(path), File.stat!(path).mode})
            answer("helm", all)

          "helm", ["upgrade", "--install", "ehos", package | _] ->
            send(test_pid, {:package, package, File.exists?(package)})
            nil

          _program, _args ->
            nil
        end)

      assert {:ok, _message} = Install.server(opts)
      assert_received {:registry, path, config, mode}
      assert Bitwise.band(mode, 0o777) == 0o600

      assert Jason.decode!(config) == %{
               "auths" => %{"ghcr.io" => %{"auth" => Base.encode64("octocat:#{@token}")}}
             }

      # Installed from the pulled package, with the credential already gone, and all of it after.
      assert_received {:package, package, true}
      assert String.ends_with?(package, ".tgz")
      refute File.exists?(path) or File.exists?(Path.dirname(path))

      for {_program, args} <- calls.() do
        refute Enum.any?(args, &(&1 =~ @token))
        refute "--registry-config" in args and hd(args) != "pull"
      end

      # A checkout's chart is packaged here, and pulls nothing of EHOS's.
      calls = record_calls()
      assert {:ok, _message} = Install.server(Keyword.put(opts, :source, @source))

      refute Enum.any?(
               calls.(),
               &match?({"helm", ["pull", "oci://ghcr.io/empoweredhouse/" <> _ | _]}, &1)
             )
    end

    test "refuses a release's chart with no GHCR_TOKEN before it changes anything", %{opts: opts} do
      chart = "oci://ghcr.io/empoweredhouse/charts/ehos@" <> @digest

      opts =
        opts
        |> Keyword.put(:source, %EhosPlatform.Source{chart: {:oci, chart}, modules: nil})
        |> Keyword.put(:token, nil)

      calls = record_calls()
      assert {:error, message} = Install.server(opts)
      assert message =~ "set GHCR_TOKEN" and message =~ "on every installation"
      refute Enum.any?(calls.(), fn {program, _args} -> program == "helm" end)
    end

    test "says GHCR refused the chart, in words that fit, and nothing for another failure", %{
      opts: opts
    } do
      chart = "oci://ghcr.io/empoweredhouse/charts/ehos@" <> @digest
      opts = Keyword.put(opts, :source, %EhosPlatform.Source{chart: {:oci, chart}, modules: nil})

      for {output, said} <- [
            {~s(GET "https://ghcr.io/token": response status code 403: denied: denied),
             "needs read:packages"},
            {~s(GET "https://ghcr.io/v2/x/manifests/sha256:401403": response status code 404: manifest unknown),
             nil},
            {"open /tmp/ca.crt: permission denied", nil}
          ] do
        record_calls(fn
          "helm", ["pull", ^chart | _] -> {"Error: " <> output, 1}
          _program, _args -> nil
        end)

        assert {:error, message} = Install.server(opts)

        if said,
          do: assert(message =~ said),
          else: refute(message =~ "GHCR_TOKEN")
      end
    end

    test "names the server's command as the caller runs it", %{opts: opts, dir: dir} do
      File.rm!(Path.join(dir, "kubeconfig"))

      assert {:error, message} =
               Install.server(Keyword.put(opts, :server_command, "ehosctl server"))

      assert message =~ "Open the tunnel first: `ehosctl server tunnel`"
    end

    # ehos-tools#197: the first person is invited with a command of the caller's, not a line of
    # kubectl that a bare `kubectl` shadowed by asdf's shims cannot run.
    test "ends by naming the command that invites a person", %{opts: opts} do
      record_calls()

      named =
        Keyword.merge(opts,
          server_command: "ehosctl server",
          name_option: "--installation",
          name_in_commands: true
        )

      assert {:ok, message} = Install.server(named)

      # Said so that it is true after an upgrade too, which ends with the same line.
      assert message =~
               "Invite a person with `ehosctl server invite <their email> --installation " <>
                 "trial`, which prints the link that signs them in: the first one invited " <>
                 "while nobody is the platform's administrator becomes it."

      refute message =~ "kubectl"
      refute message =~ "Ehos.Release"

      # Without `:name_in_commands`, it names no installation, as the tunnel it suggests does not.
      record_calls()
      assert {:ok, unnamed} = Install.server(Keyword.put(opts, :server_command, "ehosctl server"))
      assert unnamed =~ "Invite a person with `ehosctl server invite <their email>`, which"
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

    test "stops when the cluster cannot say whether it holds the credential, and installs nothing",
         %{opts: opts} do
      calls = record_calls(pull_credential: :unreachable)

      assert {:error, message} = Install.server(Keyword.put(opts, :token, ""))
      assert message =~ "kubectl could not say whether ehos-system holds the pull credential"
      assert message =~ "127.0.0.1:16443 was refused"
      refute Enum.any?(calls.(), &match?({"helm", _}, &1))
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
      # The CA as cert-manager issues it for that host.
      calls =
        record_calls(fn
          "kubectl", args ->
            if match?(["get", "secret", "ehos-local-ca" | _], step(args)),
              do: {Base.encode64(@example_org_pem), 0}

          _program, _args ->
            nil
        end)

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

    # eh-os D-124: `--host` moved the console, and the CA still permits the old host.
    test "issues the CA again for a host it did not permit, with the same key", %{opts: opts} do
      test_pid = self()
      {:ok, reads} = Agent.start_link(fn -> 0 end)

      calls =
        record_calls(fn
          "kubectl", args ->
            if match?(["get", "secret", "ehos-local-ca" | _], step(args)) do
              # Before the apply, and once after it, the CA permits the old host; then it is issued again.
              case Agent.get_and_update(reads, &{&1, &1 + 1}) do
                read when read < 2 -> {Base.encode64(@other_host_pem), 0}
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

    # eh-os#892: on a one-CPU server an application's grants Job was never scheduled.
    test "warns, and goes on, when the nodes have less than two CPUs to allocate", %{opts: opts} do
      for {allocatable, warned?} <- [
            {"1", true},
            {"1930m", true},
            {"2", false},
            {"1 1", false},
            {"", false}
          ] do
        record_calls(fn
          "kubectl", args ->
            if match?(
                 ["get", "nodes", "-o", "jsonpath={.items[*].status.allocatable.cpu}"],
                 step(args)
               ),
               do: {allocatable, 0}

          _program, _args ->
            nil
        end)

        test = self()

        assert {:ok, _message} =
                 Install.server(Keyword.put(opts, :progress, &send(test, {:progress, &1})))

        warnings =
          for {:progress, "Warning: the cluster's nodes" <> _ = line} <- drain(), do: line

        if warned? do
          assert [warning] = warnings, allocatable
          assert warning =~ "eh-os#892"
          assert warning =~ "mix ehos.server up --ocpus 2"
        else
          assert warnings == [], allocatable
        end
      end
    end

    # eh-os#923, D-148: on 1.36 a policy made again refused every new environment's pods.
    test "warns, and goes on, when the API server is older than Kubernetes 1.37", %{opts: opts} do
      for {answer, warned?} <- [
            {{server_version("1", "36", "v1.36.4+k3s1"), 0}, true},
            {{"Warning: a line first\n" <> server_version("1", "30+", "v1.30.2-gke.1"), 0}, true},
            {{server_version("1", "37", "v1.37.1+k3s1"), 0}, false},
            {{server_version("1", "38", "v1.38.0"), 0}, false},
            {{"not JSON", 0}, false},
            {{"error: the server doesn't have a resource type", 1}, false}
          ] do
        record_calls(fn
          "kubectl", args ->
            if step(args) == ["version", "-o", "json"], do: answer

          _program, _args ->
            nil
        end)

        test = self()

        assert {:ok, _message} =
                 Install.server(Keyword.put(opts, :progress, &send(test, {:progress, &1})))

        warnings =
          for {:progress, "Warning: the cluster runs Kubernetes" <> _ = line} <- drain(),
              do: line

        if warned? do
          assert [warning] = warnings, inspect(answer)
          assert warning =~ "older than 1.37"
          assert warning =~ "eh-os#923" and warning =~ "eh-os D-148"
          assert warning =~ "mix ehos.server up"
        else
          assert warnings == [], inspect(answer)
        end
      end
    end

    test "reads the API server's version from kubectl's JSON" do
      assert Install.server_version(server_version("1", "36", "v1.36.4+k3s1")) ==
               {1, 36, "v1.36.4+k3s1"}

      assert Install.server_version(server_version("1", "27+", "v1.27.3-gke.100")) ==
               {1, 27, "v1.27.3-gke.100"}

      assert Install.server_version(~s|{"clientVersion": {"major": "1", "minor": "37"}}|) == nil
      assert Install.server_version(server_version("1", "x", "v1.x")) == nil
      assert Install.server_version("") == nil
    end

    test "reads CPU quantities as millicores" do
      assert Install.millicores("2") == 2000
      assert Install.millicores("1930m 4") == 5930
      assert Install.millicores("Warning: a line first\n1") == 1000
      assert Install.millicores("") == nil
      assert Install.millicores("1.5") == nil
    end

    test "says to open the tunnel when the cluster does not answer", %{opts: opts} do
      record_calls(fn
        "kubectl", args ->
          if match?(["get", "nodes" | _], step(args)),
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

    # eh-os D-117: a cluster that is not a server, such as k3d's, is not switched but refused.
    test "refuses a cluster where k3s's Traefik is installed, installing nothing", %{
      target: target
    } do
      calls =
        record_calls(fn
          "kubectl", args ->
            case step(args) do
              ["get", "crd", "helmcharts.helm.cattle.io" | _] -> {"crd/x", 0}
              ["get", "helmchart" | _] -> {"traefik-crd", 0}
              _other -> nil
            end

          _program, _args ->
            nil
        end)

      assert {:error, message} = Install.prerequisites(target)
      assert message =~ "HelmChart traefik-crd in kube-system"
      assert message =~ "--k3s-arg --disable=traefik@server:*"
      # eh-os D-148: k3s 1.37's Gateway API CRDs come through a binding to cluster-admin too.
      assert message =~ "disable: [traefik, gateway-api-crd]"
      assert message =~ "--k3s-arg --disable=gateway-api-crd@server:*"
      refute Enum.any?(calls.(), &match?({"helm", _}, &1))
    end

    test "installs no release when the ExternalName policy cannot be applied", %{target: target} do
      calls =
        record_calls(fn
          "kubectl", args ->
            case step(args) do
              ["apply", "-f", path | _] ->
                if Path.basename(path) == "external-names.yaml",
                  do: {"error: the server could not find the requested resource", 1}

              _other ->
                nil
            end

          _program, _args ->
            nil
        end)

      assert {:error, message} = Install.prerequisites(target)
      assert message =~ "could not find the requested resource"
      refute Enum.any?(calls.(), &match?({"helm", _}, &1))
    end

    # eh-os#828: the policy sees only what is written after it.
    test "installs no release where an ExternalName Service made before is outside the two namespaces",
         %{target: target} do
      calls =
        record_calls(fn
          "kubectl", args ->
            case step(args) do
              ["get", "services", "--all-namespaces" | _] ->
                {"ehos-addresses/office\nehos-env-production/office\nehos-ingress/console\n", 0}

              _other ->
                nil
            end

          _program, _args ->
            nil
        end)

      assert {:error, message} = Install.prerequisites(target)
      assert message =~ "outside ehos-addresses and ehos-ingress (ehos-env-production/office)"
      refute Enum.any?(calls.(), &match?({"helm", _}, &1))

      refute Enum.any?(calls.(), fn {_program, args} ->
               Enum.any?(args, &String.ends_with?(&1, "addresses-namespace.yaml"))
             end)
    end

    # eh-os#846: made before Traefik, as EHOS's chart makes it, and marked as that release's, which
    # Helm requires before it takes over a namespace it did not make.
    test "makes ehos-addresses as EHOS's chart does, marked as the ehos release's" do
      assert {:ok, namespace} =
               "addresses-namespace.yaml" |> Install.manifest() |> YamlElixir.read_from_file()

      assert namespace["kind"] == "Namespace"
      assert namespace["metadata"]["name"] == "ehos-addresses"

      assert namespace["metadata"]["annotations"] == %{
               "helm.sh/resource-policy" => "keep",
               "meta.helm.sh/release-name" => "ehos",
               "meta.helm.sh/release-namespace" => "ehos-system"
             }

      assert namespace["metadata"]["labels"] == %{
               "app.kubernetes.io/managed-by" => "Helm",
               "pod-security.kubernetes.io/enforce" => "restricted",
               "pod-security.kubernetes.io/audit" => "restricted",
               "pod-security.kubernetes.io/warn" => "restricted"
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

          # Helm prints `null` for a release installed with no values of its own.
          "helm", ["get", "values", "cnpg" | _] ->
            {"null\n", 0}

          "helm", ["get", "values", release | _] ->
            prerequisite = Enum.find(Install.prerequisite_releases(), &(&1.release == release))
            {Jason.encode!(prerequisite.values), 0}

          _program, _args ->
            nil
        end)

      assert :ok = Install.prerequisites(target)
      refute Enum.any?(calls.(), &match?({"helm", ["upgrade" | _]}, &1))

      # Each is still waited for, as `helm upgrade --wait` did.
      waited =
        for {"kubectl", args} <- calls.(),
            ["wait", "--for=condition=Available", "deployment", "--selector", selector | _] <-
              [step(args)],
            do: selector

      assert waited == [
               "app.kubernetes.io/instance=cnpg",
               "app.kubernetes.io/instance=cert-manager",
               "app.kubernetes.io/instance=trust-manager",
               "app.kubernetes.io/instance=traefik-ehos-ingress"
             ]
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
      assert upgraded == ["cnpg", "cert-manager", "trust-manager", "traefik"]
    end

    # #429: a field changed by hand, `kubectl patch` on Traefik's args, failed the upgrade, and the
    # revision before it, reading every Secret, ran on.
    test "takes each release's fields back by server-side apply", %{target: target} do
      calls = record_calls()
      assert :ok = Install.prerequisites(target)

      upgrades =
        for {"helm", ["upgrade", "--install", release | args]} <- calls.(), do: {release, args}

      assert length(upgrades) == 4

      for {release, args} <- upgrades do
        # Helm refuses --force-conflicts alone on a release Helm 3 applied client-side.
        assert "--server-side=true" in args, release
        assert "--force-conflicts" in args, release
      end
    end

    test "refuses while Traefik's release still has cluster-wide rights, installed or not", %{
      target: target
    } do
      for installed? <- [false, true] do
        record_calls(fn
          "kubectl", args ->
            if match?(["get", "clusterrole,clusterrolebinding" | _], step(args)),
              do:
                {"clusterrole.rbac.authorization.k8s.io/traefik-ehos-ingress\n" <>
                   "clusterrolebinding.rbac.authorization.k8s.io/traefik-ehos-ingress\n", 0}

          "helm", ["list", "--namespace", namespace, "--filter", "^" <> release | _]
          when installed? ->
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

          "helm", ["get", "values", release | _] when installed? ->
            prerequisite = Enum.find(Install.prerequisite_releases(), &(&1.release == release))
            {Jason.encode!(prerequisite.values), 0}

          _program, _args ->
            nil
        end)

        assert {:error, message} = Install.prerequisites(target)
        assert message =~ "still has cluster-wide rights"
        assert message =~ "traefik-ehos-ingress"
      end
    end

    test "refuses while the API server lets Traefik's account read the cluster's Secrets", %{
      target: target
    } do
      for {question, answer, expected} <- [
            {"list", {"yes", 0}, "may list the Secrets of every namespace"},
            {"get", {"yes", 0}, "may read the Secrets in ehos-system"},
            # kubectl exits 1 for its own errors as for a no: refused, never taken for one.
            {"list", {"error: You must be logged in to the server (Unauthorized)", 1},
             "Unauthorized"},
            {"get",
             {~s|Error from server (Forbidden): users "x" is forbidden: User "x" cannot | <>
                ~s|impersonate resource "serviceaccounts"|, 1}, "cannot impersonate"},
            {"list", {"error: unknown flag: --request-timeout", 1}, "unknown flag"}
          ] do
        record_calls(fn
          "kubectl", args ->
            case step(args) do
              ["auth", "can-i", ^question | _] -> answer
              _other -> nil
            end

          _program, _args ->
            nil
        end)

        assert {:error, message} = Install.prerequisites(target)
        assert message =~ expected
      end
    end

    test "asks the API server as Traefik's account, with a deadline", %{target: target} do
      calls = record_calls()
      assert :ok = Install.prerequisites(target)

      asked =
        for {"kubectl", args} <- calls.(), ["auth", "can-i" | rest] <- [step(args)], do: rest

      assert asked == [
               [
                 "list",
                 "secrets",
                 "--all-namespaces",
                 "--as=system:serviceaccount:ehos-ingress:traefik",
                 "--request-timeout=10s"
               ],
               [
                 "get",
                 "secrets",
                 "--namespace",
                 "ehos-system",
                 "--as=system:serviceaccount:ehos-ingress:traefik",
                 "--request-timeout=10s"
               ]
             ]
    end

    test "takes kubectl's no with its reason, after a warning", %{target: target} do
      record_calls(fn
        "kubectl", args ->
          if match?(["auth", "can-i" | _], step(args)),
            do: {"Warning: resource 'secrets' is not namespace scoped\nno - RBAC: no rule\n", 1}

        _program, _args ->
          nil
      end)

      assert :ok = Install.prerequisites(target)
    end

    test "takes a warning kubectl prints for no cluster-wide object", %{target: target} do
      record_calls(fn
        "kubectl", args ->
          if match?(["get", "clusterrole,clusterrolebinding" | _], step(args)),
            do: {"Warning: client-side throttling, waited 1.2s\n", 0}

        _program, _args ->
          nil
      end)

      assert :ok = Install.prerequisites(target)
    end

    test "asks only for Traefik's own release's cluster-wide objects", %{target: target} do
      calls = record_calls()
      assert :ok = Install.prerequisites(target)

      [args] =
        for {"kubectl", args} <- calls.(),
            ["get", "clusterrole,clusterrolebinding" | rest] <- [step(args)],
            do: rest

      assert value_of(args, "--selector") == "app.kubernetes.io/instance=traefik-ehos-ingress"
    end

    test "pulls CloudNativePG's chart by its digest, as the other two" do
      for release <- Install.prerequisite_releases() do
        assert release.chart =~ ~r/\Aoci:\/\/[a-z0-9.\/_-]+@sha256:[0-9a-f]{64}\z/, release.title
      end
    end
  end

  describe "chart/2 from a release" do
    # eh-os D-92: a release's chart is pulled by the digest its release.json names, which Helm
    # checks, and installed from what was pulled; nothing is packaged.
    @tag evidence: "eh-os D-92"
    test "pulls the chart by its digest and installs it, packaging nothing", %{tmp_dir: tmp_dir} do
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

      # With no credential given, Helm's own login, if any, is what pulls it.
      assert [{"helm", ["pull", ^chart, "--destination", destination]}, {"helm", upgrade}] =
               Enum.filter(calls.(), &match?({"helm", _}, &1))

      assert ["upgrade", "--install", "ehos", package | _] = upgrade
      assert Path.dirname(package) == destination
    end

    # ehos-tools#543: Keyword.fetch!/2's KeyError would hold `:registry_auth`, the token in it.
    test "refuses a missing option by its name, and holds none of the others" do
      target = %Install{context: "ehos-trial", host: @host, source: @source}

      error =
        assert_raise KeyError, fn ->
          Install.chart(target, digest: @digest, ca_file: "/ca.crt", registry_auth: {"u", @token})
        end

      assert error == %KeyError{key: :repository}
    end
  end

  describe "pull_credential/1" do
    test "is there, not there, or unknown when kubectl could not say (#174, #300)" do
      target = %Install{
        context: "ehos-acme",
        host: @host,
        kubeconfig: "/k",
        source: @source,
        runner: CommandRunnerMock
      }

      for {answer, expected} <- [
            {{"secret/ehos-pull-credential\n", 0}, {:ok, true}},
            {{~s|Error from server (NotFound): secrets "ehos-pull-credential" not found|, 1},
             {:ok, false}},
            # What kubectl answers before EHOS was ever installed (#300).
            {{~s|Error from server (NotFound): namespaces "ehos-system" not found|, 1},
             {:ok, false}},
            {{~s|Error from server (NotFound): namespaces "other" not found|, 1}, :error},
            {{"Error from server (NotFound): the server could not find the requested resource",
              1}, :error},
            {{"Unable to connect to the server: i/o timeout", 1}, :error}
          ] do
        expect(CommandRunnerMock, :run, fn "kubectl", args ->
          assert ["--kubeconfig", "/k", "--context", "ehos-acme", "get", "secret" | _] = args
          answer
        end)

        case expected do
          :error ->
            assert {:error, message} = Install.pull_credential(target)
            assert message =~ "kubectl could not say"
            # kubectl's own answer is in it.
            {_output, 1} = answer
            assert message =~ elem(answer, 0)

          expected ->
            assert Install.pull_credential(target) == expected
        end
      end
    end
  end

  describe "installed/1" do
    setup %{tmp_dir: tmp_dir} do
      home = Path.join(tmp_dir, "ehos")
      File.mkdir_p!(Path.join(home, "acme"))
      File.write!(Path.join([home, "acme", "kubeconfig"]), "{}")
      %{opts: [runner: CommandRunnerMock, home: home, name: "acme"], home: home}
    end

    # Helm's answers, in the order they are asked: the history, then a revision's values.
    defp helm_answers(answers) do
      test_pid = self()

      for answer <- answers do
        expect(CommandRunnerMock, :run, fn "helm", args ->
          send(test_pid, {:helm, args})
          answer
        end)
      end
    end

    defp history(revisions) do
      listed =
        for {revision, status} <- revisions do
          %{
            "revision" => revision,
            "updated" => "2026-10-12T12:40:00+00:00",
            "status" => status,
            "chart" => "ehos-0.5.0",
            "app_version" => "0.5.0",
            "description" => "#{status} at #{revision}"
          }
        end

      {Jason.encode!(listed) <> "\n", 0}
    end

    @installed %{"version" => "0.5.0", "image" => "i", "chart" => "c"}

    # The revision's manifest, with the governance plane's four eyes as it renders it, or without.
    defp manifest(nil), do: {"---\nkind: Deployment\n", 0}

    # As the chart renders it: a Secret's data first, then the migrations' container, which gets
    # the server's value, then the server's.
    defp manifest(on) do
      {"""
       ---
       kind: Secret
       data:
         secret-key-base: c2VjcmV0
       ---
       kind: Deployment
       spec:
         template:
           spec:
             initContainers:
               - name: migrate
                 env:
                   - name: EHOS_PROMOTION_FOUR_EYES
                     value: "#{on}"
             containers:
               - name: governance
                 env:
                   - name: EHOS_PROMOTION_FOUR_EYES
                     value: "#{on}"
       """, 0}
    end

    # eh-os D-128, #350: what the server runs with, given or decided by the chart, from the
    # objects the deployed revision applied; nothing when it does not say or cannot be read.
    test "reads whether the deployed revision's server runs with four eyes", %{opts: opts} do
      for {answer, expected} <- [
            {manifest(true), true},
            {manifest(false), false},
            {manifest(nil), nil},
            # Not as the chart renders it: not read.
            {{"- name: EHOS_PROMOTION_FOUR_EYES\n  value: true\n", 0}, nil},
            {{"Error: something\n", 1}, nil}
          ] do
        helm_answers([
          history([{1, "deployed"}]),
          {Jason.encode!(%{"installed" => @installed}), 0},
          answer
        ])

        assert {:ok, %{four_eyes: nil, four_eyes_runs: ^expected}} = Install.installed(opts)
        assert_received {:helm, ["history" | _]}
        assert_received {:helm, ["get", "values" | _]}
        assert_received {:helm, ["get", "manifest", "ehos", "--namespace", "ehos-system" | args]}
        assert value_of(args, "--revision") == "1"
        assert value_of(args, "--kube-context") == "ehos-acme"
        refute "--output" in args or "json" in args
      end
    end

    test "reads what server/1 recorded in the last deployed revision, through the installation's kubeconfig and context",
         %{opts: opts, home: home} do
      helm_answers([
        history([{1, "superseded"}, {2, "deployed"}]),
        {"WARNING: something\n" <>
           Jason.encode!(%{
             "installed" => @installed,
             "image" => %{"digest" => @digest},
             "governance" => %{"host" => @host},
             "a" => 1
           }) <> "\nWARNING: after\n", 0},
        manifest(nil)
      ])

      assert Install.installed(opts) ==
               {:ok,
                %{
                  running: @installed,
                  digest: @digest,
                  host: @host,
                  sign_in: nil,
                  four_eyes: nil,
                  four_eyes_runs: nil,
                  mail: nil,
                  last: nil
                }}

      assert_received {:helm, ["history", "ehos", "--namespace", "ehos-system" | args]}
      assert value_of(args, "--kube-context") == "ehos-acme"
      assert value_of(args, "--kubeconfig") == Path.join([home, "acme", "kubeconfig"])
      assert value_of(args, "--output") == "json"

      assert_received {:helm, ["get", "values", "ehos", "--namespace", "ehos-system" | args]}
      assert value_of(args, "--revision") == "2"
      assert value_of(args, "--kube-context") == "ehos-acme"
    end

    test "reads the deployed revision when a later one failed or is pending, and says which", %{
      opts: opts
    } do
      for status <- ["failed", "pending-upgrade"] do
        helm_answers([
          history([{3, "superseded"}, {4, "deployed"}, {5, status}]),
          {Jason.encode!(%{"installed" => @installed}), 0},
          manifest(nil)
        ])

        assert {:ok, %{running: @installed, last: last}} = Install.installed(opts)
        assert last == %{revision: 5, status: status, description: "#{status} at 5"}
        assert_received {:helm, ["history" | _]}
        assert_received {:helm, ["get", "values" | args]}
        assert value_of(args, "--revision") == "4"
      end
    end

    test "is none where EHOS is not installed, or where no revision was ever deployed", %{
      opts: opts
    } do
      helm_answers([{"Error: release: not found\n", 1}])

      assert Install.installed(opts) ==
               {:ok,
                %{
                  running: :none,
                  digest: nil,
                  host: nil,
                  sign_in: nil,
                  four_eyes: nil,
                  four_eyes_runs: nil,
                  mail: nil,
                  last: nil
                }}

      helm_answers([history([{1, "failed"}])])

      assert Install.installed(opts) ==
               {:ok,
                %{
                  running: :none,
                  digest: nil,
                  host: nil,
                  sign_in: nil,
                  four_eyes: nil,
                  four_eyes_runs: nil,
                  mail: nil,
                  last: %{revision: 1, status: "failed", description: "failed at 1"}
                }}
    end

    test "is unknown where the deployed revision recorded nothing, with the image's digest and host it runs",
         %{opts: opts} do
      for {output, digest, host} <- [
            {"null\n", nil, nil},
            {~s({"image":{"digest":"#{@digest}"},"governance":{"host":"#{@host}"}}\n), @digest,
             @host},
            {~s({"installed":{"version":1},"image":"x","governance":{"host":"no host!"}}), nil,
             nil},
            {~s({"image":{"digest":"sha256:short"}}), nil, nil}
          ] do
        helm_answers([history([{1, "deployed"}]), {output, 0}, manifest(nil)])

        assert Install.installed(opts) ==
                 {:ok,
                  %{
                    running: :unknown,
                    digest: digest,
                    host: host,
                    sign_in: nil,
                    four_eyes: nil,
                    four_eyes_runs: nil,
                    mail: nil,
                    last: nil
                  }}
      end
    end

    # eh-os D-113: the limits server/1 wrote, for `ehosctl upgrade` to keep; anything the chart
    # would not take is left to its default.
    test "reads the sign-in limits the deployed revision was given", %{opts: opts} do
      for {sign_in, expected} <- [
            {%{"absolute" => "30d", "idle" => "14d"}, %{"absolute" => "30d", "idle" => "14d"}},
            {%{"absolute" => "30d"}, %{"absolute" => "30d"}},
            {%{"absolute" => "30m", "idle" => 3600, "other" => "1h"}, nil},
            {"30d", nil}
          ] do
        helm_answers([
          history([{1, "deployed"}]),
          {Jason.encode!(%{"installed" => @installed, "governance" => %{"signIn" => sign_in}}),
           0},
          manifest(nil)
        ])

        assert {:ok, %{sign_in: ^expected}} = Install.installed(opts)
      end
    end

    # eh-os D-105: as the chart reads it, so a value set by hand with `helm --set` is kept too.
    test "reads whether the deployed revision's promotions need a second person", %{opts: opts} do
      for {promotion, expected} <- [
            {%{"fourEyes" => false}, false},
            {%{"fourEyes" => "false"}, false},
            {%{"fourEyes" => true}, true},
            {%{"fourEyes" => "no"}, true},
            {%{}, nil},
            {"false", nil}
          ] do
        helm_answers([
          history([{1, "deployed"}]),
          {Jason.encode!(%{
             "installed" => @installed,
             "governance" => %{"promotion" => promotion}
           }), 0},
          manifest(nil)
        ])

        assert {:ok, %{four_eyes: ^expected}} = Install.installed(opts)
      end
    end

    # eh-os D-36: the server server/1 wrote, for `ehosctl upgrade` to keep, never its password;
    # anything server/1 would not have written is none.
    test "reads the SMTP server the deployed revision was given", %{opts: opts} do
      smtp = %{"host" => "smtp.example.com", "port" => 587, "username" => "ehos"}

      for {mail, expected} <- [
            {%{
               "from" => "e@example.com",
               "smtp" => Map.put(smtp, "password", %{"secretName" => "ehos-smtp"})
             }, %{"from" => "e@example.com", "smtp" => smtp}},
            {%{
               "from" => "e@example.com",
               "smtp" => %{"host" => "h", "port" => 25, "username" => ""}
             }, %{"from" => "e@example.com", "smtp" => %{"host" => "h", "port" => 25}}},
            {%{"from" => "", "smtp" => %{"host" => "", "port" => 587}}, nil},
            {"mail", nil},
            # Set by hand with the chart's default port, which `helm get values` does not show.
            {%{"from" => "e@example.com", "smtp" => %{"host" => "h"}},
             %{"from" => "e@example.com", "smtp" => %{"host" => "h", "port" => 587}}},
            # Not what server/1 writes: said, never read as no mail.
            {%{"from" => "e@example.com", "smtp" => %{"host" => "h", "port" => "587"}},
             :unreadable},
            {%{"from" => "EHOS <e@example.com>", "smtp" => %{"host" => "h"}}, :unreadable},
            {%{"from" => "e@example.com", "smtp" => %{"host" => "h", "tls" => false}},
             :unreadable},
            {%{
               "from" => "e@example.com",
               "smtp" => %{
                 "host" => "h",
                 "username" => "u",
                 "password" => %{"secretName" => "mine"}
               }
             }, :unreadable},
            {%{"from" => "e@x\nBcc: y@z.com", "smtp" => %{"host" => "h", "port" => 587}},
             :unreadable}
          ] do
        helm_answers([
          history([{1, "deployed"}]),
          {Jason.encode!(%{"installed" => @installed, "governance" => %{"mail" => mail}}), 0},
          manifest(nil)
        ])

        assert {:ok, %{mail: ^expected}} = Install.installed(opts)
      end
    end

    # What the chart and a mail header take: anything else would fail at the server, or change the
    # header, once EHOS sends with it.
    test "takes only hosts, senders and users an SMTP server and a header take" do
      for host <- ["smtp.example.com", "mail", "smtp-1.eu.example.org"],
          do: assert(Install.mail_host?(host), host)

      for host <- [
            "a..b",
            "-a.b",
            "a-.b",
            "x_y.com",
            "a b",
            "",
            String.duplicate("a", 64) <> ".com"
          ],
          do: refute(Install.mail_host?(host), host)

      for address <- ["ehos@example.com", "o'brien@x.io", "a.b+c@d-e.f.com"],
          do: assert(Install.mail_address?(address), address)

      rlo = <<0xE2, 0x80, 0xAE>>

      for address <- [
            <<0xFF>> <> "@b.co",
            "a" <> <<0xC2, 0x85>> <> "@b.co",
            "a" <> rlo <> "@b.co",
            "a@b",
            "a b@c.de",
            "<a>@b.co",
            "a,b@c.de",
            "a@b@c.de",
            ".ehos@x.com",
            "ehos.@x.com",
            "a..b@x.com",
            "a\r\nBcc: x@y.com",
            String.duplicate("a", 65) <> "@b.co"
          ],
          do: refute(Install.mail_address?(address), inspect(address))

      assert Install.mail_username?("ehos@example.com")
      refute Install.mail_username?("u" <> <<0xE2, 0x80, 0x8B>>)
      refute Install.mail_username?("a b")
    end

    test "says why it could not read the release", %{opts: opts} do
      helm_answers([{"Error: Kubernetes cluster unreachable\n", 1}])
      assert {:error, message} = Install.installed(opts)
      assert message =~ "cluster unreachable"
      assert message =~ "Is the tunnel open? `mix ehos.server tunnel` opens it."

      helm_answers([{"not json", 0}])
      assert {:error, message} = Install.installed(opts)
      assert message =~ "`helm history` gave something other than the release's revisions"

      helm_answers([{~s([{"revision":1}]), 0}])
      assert {:error, message} = Install.installed(opts)
      assert message =~ "a revision without its number or status"

      helm_answers([history([{1, "deployed"}]), {"[1]", 0}])
      assert {:error, message} = Install.installed(opts)
      assert message =~ "`helm get values` gave something other than the release's values"

      helm_answers([history([{1, "deployed"}]), {"Error: timeout\n", 1}])
      assert {:error, message} = Install.installed(opts)
      assert message =~ "Is the tunnel open?"

      assert {:error, message} =
               Install.installed(
                 Keyword.merge(opts, name: "other", server_command: "ehosctl server")
               )

      assert message =~ "`ehosctl server tunnel`"

      assert {:error, message} =
               Install.installed(
                 Keyword.merge(opts,
                   name: "other",
                   server_command: "ehosctl server",
                   name_option: "--installation",
                   name_in_commands: true
                 )
               )

      assert message =~ "`ehosctl server tunnel --installation other`"
    end
  end

  # ehos-tools#197: EHOS's release command (eh-os D-35), as an operator ran it with kubectl.
  describe "invite/1" do
    setup %{tmp_dir: tmp_dir} do
      home = Path.join(tmp_dir, "ehos")
      File.mkdir_p!(Path.join(home, "acme"))
      File.write!(Path.join([home, "acme", "kubeconfig"]), "{}")

      opts = [
        runner: CommandRunnerMock,
        home: home,
        name: "acme",
        email: "ada@example.com",
        server_command: "ehosctl server"
      ]

      %{opts: opts, home: home}
    end

    # As EHOS writes one: 32 random bytes in URL-safe Base64 without padding.
    @token "AbC-dEf_0123456789AbC-dEf_0123456789AbC-dEf"
    @link "https://ehos.152-70-8-238.sslip.io/people/log-in/" <> @token

    # kubectl's answer to the release command, and the arguments it was run with, for the test.
    defp kubectl_answers(answer) do
      test_pid = self()

      expect(CommandRunnerMock, :run_bounded, fn "kubectl", args, timeout ->
        send(test_pid, {:kubectl, args, timeout})
        answer
      end)
    end

    test "runs EHOS's release command in the governance container, through the installation's " <>
           "kubeconfig and context, and returns the link it printed",
         %{opts: opts, home: home} do
      kubectl_answers(
        {"12:00:01.123 [info] Some log line before\n" <>
           "Invited ada@example.com. This link signs them in once, within 15 minutes:\n" <>
           @link <>
           "\nNobody was administrator yet: ada@example.com is ehos.administrator now.\n", 0}
      )

      assert Install.invite(opts) ==
               {:ok,
                %{
                  invited:
                    "Invited ada@example.com. This link signs them in once, within 15 minutes:",
                  link: @link,
                  administrator:
                    "Nobody was administrator yet: ada@example.com is ehos.administrator now.",
                  interrupted: nil
                }}

      assert_received {:kubectl, args, timeout}
      assert timeout == :timer.minutes(2)

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
               ~S|Ehos.Release.invite("ada@example.com")|
             ]
    end

    # ehos-tools#543, as for server/1.
    test "refuses a missing :email by its name", %{opts: opts} do
      assert_raise KeyError, "key :email not found", fn ->
        Install.invite(Keyword.delete(opts, :email))
      end
    end

    test "returns no administrator's line once someone is administrator, a joined person's " <>
           "included",
         %{opts: opts} do
      kubectl_answers(
        {"Invited ada@example.com. This link signs them in once, within 15 minutes:\r\n" <>
           @link <> "\r\n", 0}
      )

      assert {:ok, %{link: @link, administrator: nil}} = Install.invite(opts)
    end

    # An address EHOS takes may hold a quote, a backslash, `#{`, a parenthesis or a `#`: each
    # would end the string, interpolate or comment out the rest if it were pasted into the code.
    test "evaluates to that one call with that very address, whatever the address holds", %{
      opts: opts
    } do
      for email <- [
            ~S|a")<>throw(:injected)<>("@example.com|,
            ~S|a\")<>throw(:injected)<>(\"@example.com|,
            ~S|#{throw(:injected)}@example.com|,
            ~S|\#{throw(:injected)}@example.com|,
            ~S|a"<>throw(:injected)#@example.com|,
            ~S|a'<>throw(:injected)<>'@example.com|,
            ~S|"""@example.com|,
            ~S|a\@example.com|,
            "-o@example.com",
            "ådå@exämple.com"
          ] do
        kubectl_answers(
          {"Invited x. This link signs them in once, within 15 minutes:\n#{@link}", 0}
        )

        assert {:ok, _invited} = Install.invite(Keyword.put(opts, :email, email))
        assert_received {:kubectl, args, _timeout}
        expression = List.last(args)

        assert {{:., _, [{:__aliases__, _, [:Ehos, :Release]}, :invite]}, _, [^email]} =
                 Code.string_to_quoted!(expression)

        # Evaluated against a stand-in for EHOS's module (test/support/ehos_release.ex): a
        # `throw/1` that got out of the string would end this test here.
        assert {:ok, []} = Code.eval_string(expression)
        assert_received {:invited, ^email}
      end
    end

    test "refuses before kubectl runs an address EHOS would refuse, or one that acts on the " <>
           "terminal",
         %{opts: opts} do
      for email <- [
            "",
            "ada",
            "@example.com",
            "ada@",
            "ada@b@example.com",
            "ada @example.com",
            "ada@example.com,alan@example.com",
            "ada@example.com;alan@example.com",
            "ada@example.com\nalan@example.com",
            "ada" <> <<0xA0::utf8>> <> "@example.com",
            "ada@example.com" <> <<0xA0::utf8>>,
            "ada@example" <> <<0x3000::utf8>> <> ".com",
            "ada\0@example.com",
            "ada" <> <<0xAD::utf8>> <> "@example.com",
            "ada\e[2J@example.com",
            "ada" <> <<0x202E::utf8>> <> "@example.com",
            "ada" <> <<0xFF>> <> "@example.com",
            String.duplicate("a", 150) <> "@example.com"
          ] do
        # No kubectl answer is expected: Mox fails the test if it is run.
        assert {:error, message} = Install.invite(Keyword.put(opts, :email, email)), email
        assert message =~ "EHOS takes"
      end
    end

    test "finds the link past a log line, and when kubectl failed after EHOS printed it", %{
      opts: opts
    } do
      kubectl_answers(
        {"Invited ada@example.com. This link signs them in once, within 15 minutes:\n" <>
           "12:00:01.123 [info] a log line from stderr\n" <> @link <> "\n", 0}
      )

      assert {:ok, %{link: @link, interrupted: nil}} = Install.invite(opts)

      kubectl_answers(
        {"Invited ada@example.com. This link signs them in once, within 15 minutes:\n" <>
           @link <> "\nerror: lost connection to pod\n", 1}
      )

      assert {:ok, %{link: @link, administrator: nil, interrupted: interrupted}} =
               Install.invite(opts)

      assert interrupted =~ "kubectl failed with exit status 1 after EHOS printed the link"
      assert interrupted =~ "if nobody was the platform's administrator, this person is now"
    end

    test "takes no link whose token was cut short or that carries more", %{opts: opts} do
      for link <- [
            String.slice(@link, 0..-5//1),
            @link <> "#fragment",
            @link <> "?a=b",
            String.replace(@link, "https", "ftp")
          ] do
        kubectl_answers(
          {"Invited ada@example.com. This link signs them in once:\n#{link}\n" <>
             "error: lost connection to pod\n", 1}
        )

        assert {:error, message} = Install.invite(opts), link
        refute message =~ @token
      end
    end

    test "hides a sign-in link in what a failed kubectl printed", %{opts: opts} do
      kubectl_answers(
        {"Invited ada@example.com. This link signs them in once:\n" <>
           "https://ehos.example.org/people/log-in/SFMyNTY.secret\u001B[2J\n" <>
           "error: lost connection to pod\n", 1}
      )

      assert {:error, message} = Install.invite(opts)
      assert message =~ "https://ehos.example.org/people/log-in/[hidden]"
      refute message =~ "SFMyNTY.secret"
    end

    test "says why EHOS did not invite, from the first line of what it raised", %{opts: opts} do
      kubectl_answers(
        {~S|** (ArgumentError) cannot invite "ada@example.com": they are disabled; re-enable | <>
           "them in the console\n    (ehos 0.6.0) lib/ehos/release.ex:153: " <>
           "Ehos.Release.print_invitation/1\n", 1}
      )

      assert Install.invite(opts) ==
               {:error,
                "EHOS did not invite ada@example.com: (ArgumentError) cannot invite " <>
                  ~S|"ada@example.com": they are disabled; re-enable them in the console|}
    end

    test "says to open the tunnel when kubectl could not reach the cluster, or did not finish", %{
      opts: opts
    } do
      kubectl_answers({"The connection to the server 127.0.0.1:16443 was refused\n", 1})
      assert {:error, message} = Install.invite(opts)
      assert message =~ "`kubectl` failed with exit status 1:\nThe connection to the server"
      assert message =~ "Is the tunnel open? `ehosctl server tunnel` opens it."

      kubectl_answers({:error, :timeout})
      assert {:error, message} = Install.invite(opts)
      assert message =~ "did not finish within 2 minutes, and no link reached ehosctl"
      assert message =~ "EHOS may still have invited them"
      assert message =~ "Is the tunnel open?"

      kubectl_answers({:error, :not_found})
      assert {:error, message} = Install.invite(opts)
      assert message =~ "`kubectl` is not installed, or not at the version EHOS pins"
    end

    test "passes on what EHOS printed when it holds no link in the form this version knows", %{
      opts: opts
    } do
      for output <- [
            "Invited ada@example.com. This link signs them in once, within 15 minutes:\n" <>
              "javascript:alert(1)\n",
            "Invited ada@example.com. This link signs them in once:\n" <>
              "https://ehos.example.org/people/log-in/\n",
            "Invited ada@example.com. This link signs them in once:\n" <>
              "https://ehos.example.org/people/log-in/abc\e[2J\n",
            "Something else entirely\n"
          ] do
        kubectl_answers({output, 0})
        assert {:error, message} = Install.invite(opts)

        assert message =~
                 "EHOS ran the invitation of ada@example.com but printed no sign-in link"

        assert String.ends_with?(message, ":\n" <> output)
      end
    end

    test "says to open the tunnel when there is no kubeconfig, and refuses a name that is not one",
         %{opts: opts} do
      assert {:error, message} = Install.invite(Keyword.put(opts, :name, "other"))
      assert message =~ "Open the tunnel first: `ehosctl server tunnel`"

      assert {:error, message} = Install.invite(Keyword.put(opts, :name, "Not A Name"))
      assert message =~ "name"
    end

    test "names the installation in the tunnel it says to open, when asked to", %{opts: opts} do
      opts =
        Keyword.merge(opts, name: "other", name_option: "--installation", name_in_commands: true)

      assert {:error, message} = Install.invite(opts)
      assert message =~ "Open the tunnel first: `ehosctl server tunnel --installation other`"
    end
  end

  defp record_calls(override \\ fn _program, _args -> nil end)

  defp record_calls(opts) when is_list(opts) do
    answer =
      case Keyword.get(opts, :pull_credential, true) do
        true -> {"secret/ehos-pull-credential\n", 0}
        false -> {~s|Error from server (NotFound): secrets "ehos-pull-credential" not found|, 1}
        :unreachable -> {"The connection to the server 127.0.0.1:16443 was refused", 1}
      end

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

      # As the API server answers for a Traefik confined to its namespaces.
      ["auth", "can-i" | _] ->
        {"no", 1}

      _other ->
        {"", 0}
    end
  end

  defp answer("helm", ["package" | _]),
    do: {"Successfully packaged chart and saved it to: /tmp/x/ehos-0.1.0.tgz\n", 0}

  # `helm pull` saves the chart where it is told.
  defp answer("helm", ["pull", _reference, "--destination", destination | _]) do
    File.write!(Path.join(destination, "ehos-0.5.0.tgz"), "chart")
    {"Pulled: ghcr.io/empoweredhouse/charts/ehos\n", 0}
  end

  # `helm pull --untar` unpacks the chart where it is told: Traefik's, with its CRDs and Hub's.
  defp answer("helm", ["pull", _reference, "--untar", "--untardir", dir | _]) do
    crds = Path.join(dir, "traefik/crds")
    File.mkdir_p!(crds)

    for name <- ["traefik.io_middlewares", "traefik.io_ingressroutes", "hub.traefik.io_apis"],
        do: File.write!(Path.join(crds, name <> ".yaml"), "kind: CustomResourceDefinition\n")

    {"Pulled: ghcr.io/traefik/helm/traefik\n", 0}
  end

  defp answer(_program, _args), do: {"", 0}

  # The arguments after the ones that point kubectl at the cluster.
  defp step(["--kubeconfig", _, "--context", _ | rest]), do: rest
  defp step(["--context", _ | rest]), do: rest
  defp step(args), do: args

  # `kubectl version -o json`'s answer, its client's version beside the API server's.
  defp server_version(major, minor, git_version) do
    Jason.encode!(%{
      "clientVersion" => %{"major" => "1", "minor" => "37", "gitVersion" => "v1.37.1"},
      "serverVersion" => %{"major" => major, "minor" => minor, "gitVersion" => git_version}
    })
  end

  defp value_of(args, flag), do: args |> Enum.drop_while(&(&1 != flag)) |> Enum.at(1)

  defp drain(acc \\ []) do
    receive do
      message -> drain([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "traefik_serves/1" do
    # eh-os#846: a namespaced Traefik serves no console from ehos-system.
    test "refuses an EHOS release before 0.17.0, and judges nothing that names no release" do
      assert {:error, message} = Install.traefik_serves(%{"version" => "0.16.0"})
      assert message =~ "EHOS 0.16.0 keeps its console's route"
      assert {:error, _} = Install.traefik_serves(%{"version" => "0.17.0-dev"})

      assert :ok = Install.traefik_serves(%{"version" => "0.17.0"})
      assert :ok = Install.traefik_serves(%{"version" => "1.0.0"})
      assert :ok = Install.traefik_serves(nil)
      assert :ok = Install.traefik_serves(%{"version" => "not a version"})
    end
  end
end
