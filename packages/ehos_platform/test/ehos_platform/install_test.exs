defmodule EhosPlatform.InstallTest do
  use ExUnit.Case, async: true

  import Hammox
  import EhosPlatform.TestSupport

  alias EhosPlatform.CertificateLogMock
  alias EhosPlatform.ClockMock
  alias EhosPlatform.CommandRunnerMock
  alias EhosPlatform.DnsMock
  alias EhosPlatform.EnvMock
  alias EhosPlatform.Install
  alias EhosPlatform.PublicCertificates
  alias EhosPlatform.Source

  doctest Install

  setup :verify_on_exit!

  @moduletag :tmp_dir

  # What kubectl names cert-manager's kind Certificate by, once cert-manager is installed.
  @certificate_crd "customresourcedefinition.apiextensions.k8s.io/certificates.cert-manager.io"

  @digest "sha256:" <> String.duplicate("ab", 32)
  # An eh-os checkout the commands are told about; every command is the mock's.
  @source Source.checkout("/src/eh-os")
  # The operator's home as the system has it, which no test creates.
  @system_home "/home/operator"
  # Test CAs, certificates only, made with openssl: one whose name constraints permit @host alone
  # and exclude every IP address, as the installation's CA's do, and one constraining names alone,
  # as it did before.
  @ca_pem File.read!("test/support/fixtures/certificates/ca-excluding-ip.pem")
  @names_only_pem File.read!("test/support/fixtures/certificates/ca-names-only.pem")
  @example_org_pem File.read!("test/support/fixtures/certificates/ca-example-org.pem")
  # The installation's CA for another host, as it was before `--host` moved it (eh-os D-124).
  @other_host_pem File.read!("test/support/fixtures/certificates/ca-other-host.pem")
  @host "ehos.152-70-8-238.sslip.io"
  @token "ghp_not_a_real_token_0123456789"
  # eh-os D-117: the console's Certificate as a chart that makes it renders it, its keys in another
  # order and the name quoted, read as YAML, not as a layout; and as one from before renders it.
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

  # The shim's fields Helm is given: its update, an apply of Helm's; k3s's, as they were.
  @shim_fields_as_helms ~s([{"apiVersion":"cert-manager.io/v1","fieldsType":"FieldsV1",) <>
                          ~s("fieldsV1":{"f:metadata":{"f:labels":{"f:helm.sh/chart":{}}}},) <>
                          ~s("manager":"helm","operation":"Apply"},) <>
                          ~s({"fieldsType":"FieldsV1","fieldsV1":{},"manager":"k3s","operation":"Update"}])

  # What server/1 says of a CA it had issued again.
  @issued_again "The CA was issued again, so that it may sign #{@host} and no IP address; its " <>
                  "key is the same. Replace any copy of its old certificate you trusted with the " <>
                  "new one"

  # EHOS's namespace, applied with each Secret in case it is not there yet.
  @namespace_document %{
    "apiVersion" => "v1",
    "kind" => "Namespace",
    "metadata" => %{"name" => "ehos-system"}
  }

  # What server/1 records in the release's values, read back by installed/1.
  @installed %{"version" => "0.5.0", "image" => "i", "chart" => "c"}

  # A sign-in link as EHOS writes one: its token 32 random bytes in URL-safe Base64 without
  # padding.
  @link "https://ehos.152-70-8-238.sslip.io/people/log-in/AbC-dEf_0123456789AbC-dEf_0123456789AbC-dEf"

  # How the chart describes a server made on Oracle with no size recorded.
  @oci ~s({"name":"trial","provider":"oci"})

  # The chart's values for the SMTP server `a@b.cd` sends through, `h`, as `u`.
  @smtp_values [
    "--set-json",
    ~s(governance.mail={"from":"a@b.cd","smtp":{"host":"h",) <>
      ~s("password":{"secretKey":"password","secretName":"ehos-smtp"},"port":587,"username":"u"}})
  ]

  describe "for_host/2" do
    test "writes the installation's CA and its admission policy for another host" do
      rendered = "local-ca.yaml" |> Install.manifest() |> File.read!() |> Install.for_host(@host)

      refute rendered =~ "localhost"
      documents = YamlElixir.read_all_from_string!(rendered)

      [certificate] = Enum.filter(documents, &(&1["kind"] == "Certificate"))

      assert certificate ==
               %{
                 "apiVersion" => "cert-manager.io/v1",
                 "kind" => "Certificate",
                 "metadata" => %{"name" => "ehos-local-ca", "namespace" => "cert-manager"},
                 "spec" => %{
                   "isCA" => true,
                   "commonName" => "EHOS local cluster CA",
                   "secretName" => "ehos-local-ca",
                   "duration" => "8760h",
                   "privateKey" => %{
                     "algorithm" => "ECDSA",
                     "size" => 256,
                     "rotationPolicy" => "Never"
                   },
                   "nameConstraints" => %{
                     "critical" => true,
                     "permitted" => %{"dnsDomains" => [@host]},
                     # A constraint on names alone leaves every IP address open (RFC 5280).
                     "excluded" => %{"ipRanges" => ["0.0.0.0/0", "::/0"]}
                   },
                   "issuerRef" => %{
                     "name" => "ehos-local-selfsigned",
                     "kind" => "Issuer",
                     "group" => "cert-manager.io"
                   }
                 }
               }

      [policy] = Enum.filter(documents, &(&1["kind"] == "ValidatingAdmissionPolicy"))
      [_namespaces, _requests, names, _signing] = policy["spec"]["validations"]

      assert names["expression"] ==
               String.trim_trailing(~S"""
               !variables.local || request.resource.resource != 'certificates' || (!object.spec.?isCA.orValue(false) &&
                !has(object.spec.literalSubject) && !has(object.spec.subject) &&
                object.spec.?usages.orValue([]).all(usage,
                  usage in ['digital signature', 'key encipherment', 'server auth']) &&
                !has(object.spec.ipAddresses) && !has(object.spec.uris) &&
                !has(object.spec.emailAddresses) && !has(object.spec.otherNames) &&
                variables.names.size() > 0 &&
                (request.namespace == 'ehos-system'
                  ? variables.names.all(name, name == 'ehos.152-70-8-238.sslip.io')
                  : variables.environment != '' && variables.names.all(name,
                      name.matches('^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\\.' +
                        variables.environment + '\\.ehos\\.152-70-8-238\\.sslip\\.io$'))))
               """)

      # eh-os#828: an address's certificate in ehos-addresses, for the environment its label names.
      variables = Map.new(policy["spec"]["variables"], &{&1["name"], &1["expression"]})

      assert variables["environment"] ==
               "request.namespace == 'ehos-addresses' ? variables.labelled : ''"
    end

    test "writes the CoreDNS rule for another host, and nothing broader" do
      rendered =
        "coredns-custom.yaml" |> Install.manifest() |> File.read!() |> Install.for_host(@host)

      assert YamlElixir.read_from_string!(rendered) ==
               %{
                 "apiVersion" => "v1",
                 "kind" => "ConfigMap",
                 "metadata" => %{"name" => "coredns-custom", "namespace" => "kube-system"},
                 "data" => %{
                   "ehos.override" =>
                     ~S"rewrite stop name regex ^([^._]+\.)*ehos\.152-70-8-238\.sslip\.io\.$ " <>
                       "traefik.ehos-ingress.svc.cluster.local. answer auto\n"
                 }
               }
    end
  end

  describe "coredns-custom.yaml's rule" do
    # eh-os D-158 (eh-os#1195): RE2, as CoreDNS reads it; Elixir's Regex reads this one the same.
    setup do
      %{"data" => %{"ehos.override" => rule}} =
        "coredns-custom.yaml"
        |> Install.manifest()
        |> File.read!()
        |> Install.for_host(@host)
        |> YamlElixir.read_from_string!()

      ["rewrite", "stop", "name", "regex", pattern | _] = String.split(rule)

      %{rule: Regex.compile!(pattern)}
    end

    test "sends the console's host and every address under it to Traefik", %{rule: rule} do
      for name <- [@host, "ledger.production.#{@host}", "ledger-api.ab-12.#{@host}"] do
        assert Regex.match?(rule, name <> "."), name
      end
    end

    test "leaves the names acme-dns answers, and any other with an underscore, to the resolver",
         %{rule: rule} do
      for name <- [
            "_acme-challenge.#{@host}",
            "_acme-dns.#{@host}",
            "0b5e1c2d-4f6a._acme-dns.#{@host}",
            "_dmarc.#{@host}",
            "evil#{@host}",
            "#{@host}.example.org"
          ] do
        refute Regex.match?(rule, name <> "."), name
      end
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

      # The environment holds nothing a test does not set, the system puts the operator's home at
      # @system_home, and nothing waits.
      stub(EnvMock, :get, fn _name -> nil end)
      stub(EnvMock, :user_home, fn -> @system_home end)
      stub(ClockMock, :sleep, fn _ms -> :ok end)
      stub_now()

      %{opts: opts, dir: dir}
    end

    test "installs the prerequisites, the CA for the server's host and the chart, in the installation's context",
         %{opts: opts, dir: dir} do
      calls = record_calls()

      assert Install.server(opts) == {:ok, running(dir)}

      assert calls.() ==
               server_calls(dir, server_steps(dir))

      assert File.read!(Path.join(dir, "ca.crt")) == @ca_pem

      assert dir |> Path.join("install.json") |> File.read!() |> Jason.decode!() == %{
               "digest" => @digest,
               "host" => @host,
               "repository" => "ghcr.io/empoweredhouse/ehos"
             }
    end

    # ehos-tools#840: a move's first pass, or its wait for the console's certificate, stopped and
    # never run again.
    test "removes what a move that was abandoned left, once the installation's CA is there",
         %{opts: opts, dir: dir} do
      calls =
        record_calls(fn
          "kubectl", args ->
            case step(args) do
              ["get", "certificate.cert-manager.io/ehos-governance-public-tls" | _] ->
                {"certificate.cert-manager.io/ehos-governance-public-tls\n" <>
                   "clusterissuer.cert-manager.io/ehos-acme-console\n", 0}

              _other ->
                nil
            end

          _program, _args ->
            nil
        end)

      assert Install.server(opts) == {:ok, running(dir)}

      removed = [
        {:kubectl,
         [
           "delete",
           "certificate/ehos-governance-public-tls",
           "-n",
           "ehos-system",
           "--ignore-not-found"
         ]},
        {:kubectl,
         [
           "delete",
           "clusterissuer/ehos-acme-console",
           "clusterissuer/ehos-acme-addresses",
           "--ignore-not-found"
         ]},
        {:kubectl,
         [
           "delete",
           "validatingadmissionpolicybinding/ehos-acme-issuers",
           "validatingadmissionpolicy/ehos-acme-issuers",
           "--ignore-not-found"
         ]}
      ]

      assert calls.() ==
               server_calls(
                 dir,
                 server_steps(dir,
                   ca:
                     ca_steps() ++
                       [abandoned_step() | removed] ++ name_steps(@host) ++ [ca_secret_step()]
                 )
               )
    end

    # ehos-tools#680: after the chart gives the class, before the governance plane would restart.
    test "restarts the PostgreSQL whose pods run without its cluster's class once the chart is installed",
         %{opts: opts, dir: dir} do
      calls =
        mock_databases(
          %{
            "ehos-data" =>
              {[cnpg_cluster("shared", "ehos-platform")], [instance_pod("shared", nil)]}
          },
          %{
            "shared" => [
              {cnpg_json(cnpg_cluster("shared", "ehos-platform")),
               kubectl_list([instance_pod("shared", "ehos-platform")])}
            ]
          }
        )

      assert Install.server(opts) == {:ok, running(dir)}

      assert calls.() ==
               server_calls(
                 dir,
                 server_steps(dir,
                   databases:
                     database_list_steps(["ehos-data"]) ++
                       database_restart_steps("ehos-data", "shared") ++
                       database_poll_steps("ehos-data", "shared")
                 )
               )
    end

    # eh-os D-158 (eh-os#1236): the issuer of the console's certificate is read before the
    # prerequisites, when a new server has no kind Certificate yet.
    test "installs on a new server, where cert-manager's kind Certificate is not there yet", %{
      opts: opts,
      dir: dir
    } do
      calls = record_calls([{{:kubectl, console_issuer_step() |> elem(1)}, {"", 0}}])

      assert Install.server(opts) == {:ok, running(dir)}
      # The console's Certificate is not asked for.
      assert calls.() == server_calls(dir, server_steps(dir))
    end

    test "stops when the cluster cannot say whether cert-manager's kind is there", %{
      opts: opts,
      dir: dir
    } do
      calls =
        record_calls([
          {{:kubectl, console_issuer_step() |> elem(1)},
           {"The connection to the server was refused", 1}}
        ])

      assert Install.server(opts) ==
               {:error,
                "`kubectl` failed with exit status 1:\nThe connection to the server was refused"}

      assert calls.() == server_calls(dir, checked_steps() ++ [console_issuer_step()])
    end

    test "installs as new where cert-manager is there but the console's certificate is not", %{
      opts: opts,
      dir: dir
    } do
      calls =
        record_calls([
          {{:kubectl, console_issuer_step() |> elem(1)}, {@certificate_crd, 0}},
          {{:kubectl, console_certificate_read_step() |> elem(1)}, {"", 0}}
        ])

      assert Install.server(opts) == {:ok, running(dir)}

      assert calls.() ==
               server_calls(
                 dir,
                 server_steps(dir,
                   public: [
                     console_issuer_step(),
                     console_certificate_read_step(),
                     public_certificate_read_step()
                   ]
                 )
               )
    end

    test "stops when the console's certificate cannot be read", %{opts: opts, dir: dir} do
      calls =
        record_calls([
          {{:kubectl, console_issuer_step() |> elem(1)}, {@certificate_crd, 0}},
          {{:kubectl, console_certificate_read_step() |> elem(1)},
           {"The connection to the server was refused", 1}}
        ])

      assert Install.server(opts) ==
               {:error,
                "`kubectl` failed with exit status 1:\nThe connection to the server was refused"}

      assert calls.() ==
               server_calls(
                 dir,
                 checked_steps() ++ [console_issuer_step(), console_certificate_read_step()]
               )
    end

    # eh-os D-92: what runs, recorded for `upgrade` to read back.
    test "records what is installed in the release's values when told, and nothing otherwise", %{
      opts: opts,
      dir: dir
    } do
      installed = %{
        "version" => "0.17.0",
        "image" => "ghcr.io/empoweredhouse/ehos@#{@digest}",
        "chart" => "oci://ghcr.io/empoweredhouse/charts/ehos@#{@digest}"
      }

      for {given, extra} <- [
            # As JSON, which Helm reads whole: `--set` would split it on its commas.
            {installed,
             [
               "--set-json",
               ~s(installed={"chart":"oci://ghcr.io/empoweredhouse/charts/ehos@#{@digest}",) <>
                 ~s("image":"ghcr.io/empoweredhouse/ehos@#{@digest}","version":"0.17.0"})
             ]},
            {nil, []}
          ] do
        calls = record_calls()
        assert Install.server(Keyword.put(opts, :installed, given)) == {:ok, running(dir)}

        assert calls.() ==
                 server_calls(dir, server_steps(dir, extra: extra))
      end
    end

    # eh-os D-113: as JSON, beside the installation's description; none given, the chart's defaults.
    test "gives the chart the sign-in limits when given, and none otherwise", %{
      opts: opts,
      dir: dir
    } do
      for {given, extra} <- [
            {%{"absolute" => "30d", "idle" => "14d"},
             ["--set-json", ~s(governance.signIn={"absolute":"30d","idle":"14d"})]},
            {nil, []},
            {%{}, []}
          ] do
        calls = record_calls()
        assert Install.server(Keyword.put(opts, :sign_in, given)) == {:ok, running(dir)}

        assert calls.() ==
                 server_calls(dir, server_steps(dir, extra: extra))
      end
    end

    # eh-os D-155: only the ACME account certifies a domain of the company's own.
    test "refuses allowed domains without public certificates, before it changes anything", %{
      opts: opts
    } do
      calls = record_calls()

      assert Install.server(Keyword.put(opts, :allowed_domains, ["client.example"])) ==
               {:error,
                "Allowed domains need public certificates: Let's Encrypt issues the certificate " <>
                  "of each mapped domain. Install with public certificates first, or give no " <>
                  "allowed domain. Nothing was changed"}

      refute Enum.any?(calls.(), &match?({"helm", ["upgrade" | _]}, &1))
    end

    # eh-os D-105: only when given; none leaves it to the chart (eh-os D-128 from EHOS 0.14.0).
    test "gives the chart four eyes when given, and nothing otherwise", %{opts: opts, dir: dir} do
      for {given, extra} <- [
            {false, ["--set-json", "governance.promotion.fourEyes=false"]},
            {true, ["--set-json", "governance.promotion.fourEyes=true"]},
            {nil, []}
          ] do
        calls = record_calls()
        assert Install.server(Keyword.put(opts, :four_eyes, given)) == {:ok, running(dir)}

        assert calls.() ==
                 server_calls(dir, server_steps(dir, extra: extra))
      end
    end

    # eh-os D-36: as JSON; the password's Secret named only where the server authenticates.
    test "gives the chart the SMTP server when given, and none otherwise", %{opts: opts, dir: dir} do
      with_user = %{
        "from" => "ehos@example.com",
        "smtp" => %{"host" => "smtp.example.com", "port" => 587, "username" => "ehos"}
      }

      without_user = %{"from" => "ehos@example.com", "smtp" => %{"host" => "mail", "port" => 25}}
      empty_user = put_in(without_user, ["smtp", "username"], "")

      for {given, smtp, extra} <- [
            {with_user, [smtp_held_step()],
             [
               "--set-json",
               ~s(governance.mail={"from":"ehos@example.com","smtp":{"host":"smtp.example.com",) <>
                 ~s("password":{"secretKey":"password","secretName":"ehos-smtp"},"port":587,) <>
                 ~s("username":"ehos"}})
             ]},
            {without_user, [],
             [
               "--set-json",
               ~s(governance.mail={"from":"ehos@example.com","smtp":{"host":"mail","port":25}})
             ]},
            # The chart refuses a password's Secret without a user, after the Secrets are written.
            {empty_user, [],
             [
               "--set-json",
               ~s(governance.mail={"from":"ehos@example.com","smtp":{"host":"mail","port":25,) <>
                 ~s("username":""}})
             ]},
            {nil, [], []}
          ] do
        calls = record_calls()
        assert Install.server(Keyword.put(opts, :mail, given)) == {:ok, running(dir)}
        restart = if smtp == [], do: [], else: [restart_pending_step()]

        assert calls.() ==
                 server_calls(dir, server_steps(dir, smtp: smtp, extra: extra, restart: restart))
      end
    end

    test "writes the SMTP password from a file only this user reads, never from an argument",
         %{opts: opts, dir: dir} do
      password = "s3cret pass"
      calls = mock_secret_files()

      mail = %{"from" => "a@b.cd", "smtp" => %{"host" => "h", "port" => 587, "username" => "u"}}

      assert opts
             |> Keyword.put(:mail, mail)
             |> Keyword.put(:smtp_password, password)
             |> Install.server() == {:ok, running(dir)}

      assert_received {:secret, "ehos-smtp", contents, mode, path}
      assert Bitwise.band(mode, 0o777) == 0o600
      refute File.exists?(path)

      assert Jason.decode!(contents) == %{
               "apiVersion" => "v1",
               "kind" => "List",
               "items" => [
                 @namespace_document,
                 %{
                   "apiVersion" => "v1",
                   "kind" => "Secret",
                   "type" => "Opaque",
                   "metadata" => %{
                     "name" => "ehos-smtp",
                     "namespace" => "ehos-system",
                     "annotations" => %{"ehos.empowered.house/restart" => "pending"}
                   },
                   "data" => %{"password" => Base.encode64(password)}
                 }
               ]
             }

      for {_program, args} <- calls.(), arg <- args do
        refute arg =~ password
        refute arg =~ Base.encode64(password)
      end
    end

    test "keeps the SMTP password the cluster holds, and refuses a user with none", %{
      opts: opts,
      dir: dir
    } do
      mail = %{"from" => "a@b.cd", "smtp" => %{"host" => "h", "port" => 587, "username" => "u"}}
      opts = Keyword.put(opts, :mail, mail)

      for {answer, outcome} <- [
            {{"secret/ehos-smtp\n", 0}, :ok},
            {{~s|Error from server (NotFound): secrets "ehos-smtp" not found|, 1}, :refused},
            # A cluster EHOS was never installed in holds no password either (ehos-tools#300).
            {{~s|Error from server (NotFound): namespaces "ehos-system" not found|, 1}, :refused}
          ] do
        calls = record_calls([{smtp_held_step(), answer}])

        case outcome do
          :ok ->
            assert Install.server(opts) == {:ok, running(dir)}

            # Kept as it is: nothing written over it, and nothing restarted for it.
            assert calls.() ==
                     server_calls(
                       dir,
                       server_steps(dir,
                         smtp: [smtp_held_step()],
                         extra: @smtp_values,
                         restart: [restart_pending_step()]
                       )
                     )

          :refused ->
            assert Install.server(opts) ==
                     {:error,
                      "The SMTP server is to be reached as u, but no password for it is in the " <>
                        "cluster: set SMTP_PASSWORD to it. Nothing was changed."}

            assert calls.() ==
                     server_calls(
                       dir,
                       checked_steps() ++ [console_issuer_step(), smtp_held_step()]
                     )
        end
      end
    end

    # A password given again is not a new one; a restart a failed run left owing is made on the
    # next, and only then unmarked.
    test "restarts for a password only when it changed, or when a run before did not", %{
      opts: opts,
      dir: dir
    } do
      mail = %{"from" => "a@b.cd", "smtp" => %{"host" => "h", "port" => 587, "username" => "u"}}

      for {given, held, pending, smtp, smtp_written, restart} <- [
            {"same", Base.encode64("same"), "", [smtp_password_step()], [],
             [restart_pending_step()]},
            {"new", Base.encode64("old"), "", [smtp_password_step()], secret_steps("ehos-smtp"),
             restart_steps()},
            {nil, nil, "pending", [smtp_held_step()], [],
             [restart_pending_step() | restart_steps()]},
            {"same", Base.encode64("same"), "pending", [smtp_password_step()], [],
             [restart_pending_step() | restart_steps()]}
          ] do
        calls =
          record_calls([
            {smtp_password_step(), {"#{held}", 0}},
            {restart_pending_step(), {pending, 0}}
          ])

        assert opts
               |> Keyword.put(:mail, mail)
               |> Keyword.put(:smtp_password, given)
               |> Install.server() == {:ok, running(dir)}

        assert calls.() ==
                 server_calls(
                   dir,
                   server_steps(dir,
                     smtp: smtp,
                     smtp_written: smtp_written,
                     extra: @smtp_values,
                     restart: restart
                   )
                 )
      end
    end

    # The chart gives the password as a variable, read when the pod starts: a rotated one reaches
    # EHOS only through a restart, and one kept needs none.
    test "restarts the governance plane after it writes a password, and only then", %{
      opts: opts,
      dir: dir
    } do
      mail = %{"from" => "a@b.cd", "smtp" => %{"host" => "h", "port" => 587, "username" => "u"}}

      for {password, smtp, smtp_written, restart} <- [
            {"new", [smtp_password_step()], secret_steps("ehos-smtp"), restart_steps()},
            {nil, [smtp_held_step()], [], [restart_pending_step()]}
          ] do
        calls = record_calls()

        assert opts
               |> Keyword.put(:mail, mail)
               |> Keyword.put(:smtp_password, password)
               |> Install.server() == {:ok, running(dir)}

        assert calls.() ==
                 server_calls(
                   dir,
                   server_steps(dir,
                     smtp: smtp,
                     smtp_written: smtp_written,
                     extra: @smtp_values,
                     restart: restart
                   )
                 )
      end
    end

    # eh-os D-117: the chart makes the console's Certificate since; one cert-manager made for the
    # console's Ingress is handed to the release first, or Helm refuses to take it over. Only when
    # the chart being installed makes it: a chart from before still asks for it by the Ingress.
    test "hands a console Certificate cert-manager made for the Ingress over to a chart that makes it, first",
         %{opts: opts, dir: dir} do
      calls = mock_console_certificate("Ingress", @chart_with_certificate)

      assert Install.server(opts) == {:ok, running(dir)}

      # Then Helm 4, applying as `helm`, is given the fields the ingress-shim applied: an apply of
      # Helm's, renamed alone, since an update stays another owner to server-side apply.
      assert calls.() ==
               server_calls(
                 dir,
                 server_steps(dir,
                   adopt:
                     [render_step(ehos_values(dir)), hand_over_step()] ++
                       managed_fields_steps(@shim_fields_as_helms)
                 )
               )
    end

    # A run that freed it from the Ingress and stopped before Helm took its fields over.
    test "gives Helm the shim's fields of one handed over before, whatever the chart", %{
      opts: opts,
      dir: dir
    } do
      calls = mock_console_certificate("", @chart_without_certificate, @shim_fields)
      assert Install.server(opts) == {:ok, running(dir)}

      assert calls.() ==
               server_calls(
                 dir,
                 server_steps(dir, adopt: managed_fields_steps(@shim_fields_as_helms))
               )
    end

    # Helm applied fields the shim shares with it, with the same values, so without a conflict.
    test "joins the shim's fields to an apply Helm made already", %{opts: opts, dir: dir} do
      helms = %{
        "manager" => "helm",
        "operation" => "Apply",
        "apiVersion" => "cert-manager.io/v2",
        "fieldsType" => "FieldsV1",
        "fieldsV1" => %{"f:metadata" => %{"f:labels" => %{"f:app.kubernetes.io/name" => %{}}}}
      }

      calls = mock_console_certificate("", @chart_with_certificate, @shim_fields ++ [helms])
      assert Install.server(opts) == {:ok, running(dir)}

      # One apply of Helm's, in the version Helm applies in.
      as_helms =
        ~s([{"apiVersion":"cert-manager.io/v2","fieldsType":"FieldsV1","fieldsV1":) <>
          ~s({"f:metadata":{"f:labels":{"f:app.kubernetes.io/name":{},"f:helm.sh/chart":{}}}},) <>
          ~s("manager":"helm","operation":"Apply"},) <>
          ~s({"fieldsType":"FieldsV1","fieldsV1":{},"manager":"k3s","operation":"Update"}])

      assert calls.() ==
               server_calls(dir, server_steps(dir, adopt: managed_fields_steps(as_helms)))
    end

    # 0.5.2 renamed the shim's update `helm`'s, which server-side apply still counts as another
    # owner than Helm's apply.
    test "makes an update of Helm's, as 0.5.2 left it, Helm's apply", %{opts: opts, dir: dir} do
      left = [%{hd(@shim_fields) | "manager" => "helm"} | tl(@shim_fields)]
      calls = mock_console_certificate("", @chart_without_certificate, left)
      assert Install.server(opts) == {:ok, running(dir)}

      assert calls.() ==
               server_calls(
                 dir,
                 server_steps(dir, adopt: managed_fields_steps(@shim_fields_as_helms))
               )
    end

    test "hands it over among other owners, and leaves one no Ingress owns", %{
      opts: opts,
      dir: dir
    } do
      calls = mock_console_certificate("Certificate Ingress", @chart_with_certificate)
      assert Install.server(opts) == {:ok, running(dir)}

      assert calls.() ==
               server_calls(
                 dir,
                 server_steps(dir,
                   adopt:
                     [render_step(ehos_values(dir)), hand_over_step()] ++
                       managed_fields_steps(@shim_fields_as_helms)
                 )
               )

      calls = mock_console_certificate("Certificate", @chart_with_certificate)
      assert Install.server(opts) == {:ok, running(dir)}

      assert calls.() ==
               server_calls(dir, server_steps(dir, adopt: managed_fields_steps()))
    end

    test "leaves it with the Ingress when the chart being installed is one from before", %{
      opts: opts,
      dir: dir
    } do
      calls = mock_console_certificate("Ingress", @chart_without_certificate)
      assert Install.server(opts) == {:ok, running(dir)}

      assert calls.() ==
               server_calls(dir, server_steps(dir, adopt: [render_step(ehos_values(dir))]))
    end

    test "leaves a console Certificate the chart made alone, without rendering the chart", %{
      opts: opts,
      dir: dir
    } do
      calls = mock_console_certificate("", @chart_with_certificate)
      assert Install.server(opts) == {:ok, running(dir)}
      assert calls.() == server_calls(dir, server_steps(dir, adopt: managed_fields_steps()))
    end

    # eh-os#823: a server made before EHOS installed its own Traefik, switched.
    test "switches a server that runs k3s's Traefik to EHOS's, then installs", %{
      opts: opts,
      dir: dir
    } do
      test = self()
      {opts, calls} = mock_server_with_bundled_traefik(dir, opts, fn _args -> {"", 0} end, 3)

      assert Install.server(Keyword.put(opts, :progress, &send(test, {:progress, &1}))) ==
               {:ok, running(dir)}

      assert for({:progress, line} <- drain(), do: line) ==
               server_progress(
                 switch: [
                   "Switching the server from k3s's Traefik to EHOS's (eh-os D-117): the " <>
                     "console and its applications are down for a few minutes",
                   "k3s's Traefik is gone from the server"
                 ]
               )

      # What could still refuse came first; EHOS's Traefik and the chart only after. The cluster
      # asked once it was switched finds the API server restarting, then k3s's Traefik there
      # twice, then gone.
      assert calls.() ==
               server_calls(
                 dir,
                 server_steps(dir, k3s: true, switch: switch_steps(dir, 4), installation: @oci)
               )
    end

    test "switches a server where the HelmChart of k3s's Traefik's CRDs alone is left", %{
      opts: opts,
      dir: dir
    } do
      {opts, calls} =
        mock_server_with_bundled_traefik(dir, opts, fn _args -> {"", 0} end, 2, "traefik-crd")

      assert Install.server(opts) == {:ok, running(dir)}

      assert calls.() ==
               server_calls(
                 dir,
                 server_steps(dir, k3s: true, switch: switch_steps(dir, 3), installation: @oci)
               )
    end

    # ehos-tools#656: the switch logs in with the key `up` recorded, as every server command does.
    test "switches the server with the key up recorded for it", %{opts: opts, dir: dir} do
      {opts, calls} =
        mock_server_with_bundled_traefik(dir, opts, fn _args -> {"", 0} end, 2, "traefik-crd")

      File.write!(
        Path.join(dir, "installation.json"),
        ~s({"provider": "oci", "ssh_key": "/keys/ehos_acme"})
      )

      assert Install.server(opts) == {:ok, running(dir)}

      assert calls.() ==
               server_calls(
                 dir,
                 server_steps(dir,
                   k3s: true,
                   switch: switch_steps(dir, 3, "/keys/ehos_acme"),
                   installation: @oci
                 )
               )
    end

    test "waits for the CRDs to be gone too, not the HelmCharts alone", %{opts: opts, dir: dir} do
      {opts, calls} =
        mock_server_with_bundled_traefik(
          dir,
          opts,
          fn _args -> {"", 0} end,
          2,
          "traefik traefik-crd",
          3
        )

      assert Install.server(opts) == {:ok, running(dir)}
      # Asked once before the switch; after it, until the HelmCharts went (the API restarting,
      # then once), then three more times for the CRDs; then once by the prerequisites.
      assert calls.() ==
               server_calls(
                 dir,
                 server_steps(dir, k3s: true, switch: switch_steps(dir, 6), installation: @oci)
               )
    end

    test "installs on a k3s cluster made without it, and on a cluster that is not k3s", %{
      opts: opts,
      dir: dir
    } do
      calls =
        mock_bundled_traefik(
          "customresourcedefinition.apiextensions.k8s.io/helmcharts.helm.cattle.io",
          ""
        )

      assert Install.server(opts) == {:ok, running(dir)}
      assert calls.() == server_calls(dir, server_steps(dir, k3s: true))

      calls = mock_bundled_traefik("", "")
      assert Install.server(opts) == {:ok, running(dir)}
      assert calls.() == server_calls(dir, server_steps(dir))
    end

    test "pulls a release's chart with the registry credential, in a file only this user reads " <>
           "for the pull alone, and installs it from here",
         %{opts: opts, dir: dir} do
      chart = "oci://ghcr.io/empoweredhouse/charts/ehos@" <> @digest
      opts = Keyword.put(opts, :source, %EhosPlatform.Source{chart: {:oci, chart}, modules: nil})
      calls = mock_chart_pull(chart)

      assert Install.server(opts) == {:ok, running(dir)}
      assert_received {:registry, path, config, mode}
      assert Bitwise.band(mode, 0o777) == 0o600

      assert Jason.decode!(config) == %{
               "auths" => %{"ghcr.io" => %{"auth" => Base.encode64("octocat:#{@token}")}}
             }

      # Installed from the pulled package, with the credential already gone, and all of it after.
      assert_received {:package, true}
      refute File.exists?(path) or File.exists?(Path.dirname(path))

      assert calls.() ==
               server_calls(
                 dir,
                 server_steps(dir,
                   chart:
                     pulled_chart_steps(chart, ehos_values(dir), [
                       "--registry-config",
                       tmp("ehos-cluster", "registry.json")
                     ])
                 )
               )

      # A checkout's chart is packaged here, and pulls nothing of EHOS's.
      calls = record_calls()
      assert Install.server(Keyword.put(opts, :source, @source)) == {:ok, running(dir)}
      assert calls.() == server_calls(dir, server_steps(dir))
    end

    test "ends by naming the command that invites a person", %{opts: opts, dir: dir} do
      record_calls()

      named =
        Keyword.merge(opts,
          server_command: "ehosctl server",
          name_option: "--installation",
          name_in_commands: true
        )

      # ehos-tools#197: the first person is invited with a command of the caller's, not a line
      # of kubectl that a bare `kubectl` shadowed by asdf's shims cannot run. Said so that it is
      # true after an upgrade too, which ends with the same line.
      assert Install.server(named) ==
               {:ok,
                running(dir,
                  invite: "ehosctl server invite <their email> --installation trial"
                )}

      # Without `:name_in_commands`, it names no installation, as the tunnel it suggests does not.
      record_calls()

      assert Install.server(Keyword.put(opts, :server_command, "ehosctl server")) ==
               {:ok, running(dir, invite: "ehosctl server invite <their email>")}
    end

    # D-90: what the installation's page says it is, from what `up` recorded.
    test "describes the installation to the chart from where `up` made it", %{
      opts: opts,
      dir: dir
    } do
      for {place, vars, description} <- [
            {%{"provider" => "aws", "aws_account_id" => "1", "region" => "eu-central-1"},
             %{"instance_type" => "t4g.large"},
             ~s({"name":"trial","provider":"aws","region":"eu-central-1","size":"t4g.large"})},
            {%{"provider" => "gcp", "project" => "p", "region" => "europe-west3"},
             %{"machine_type" => "e2-standard-4"},
             ~s({"name":"trial","provider":"gcp","region":"europe-west3","size":"e2-standard-4"})},
            {%{"provider" => "oci", "tenancy_ocid" => "t", "region" => "eu-frankfurt-1"},
             %{"ocpus" => 4, "memory_gbs" => 24},
             ~s({"name":"trial","provider":"oci","region":"eu-frankfurt-1",) <>
               ~s("size":"4 OCPUs, 24 GB"})},
            # The module's default size is not recorded, so it is not said.
            {%{"provider" => "oci", "tenancy_ocid" => "t", "region" => "eu-frankfurt-1"}, %{},
             ~s({"name":"trial","provider":"oci","region":"eu-frankfurt-1"})}
          ] do
        File.write!(Path.join(dir, "installation.json"), Jason.encode!(place))
        File.write!(Path.join(dir, "server.tfvars.json"), Jason.encode!(vars))
        calls = record_calls()

        assert Install.server(opts) == {:ok, running(dir)}

        assert calls.() ==
                 server_calls(dir, server_steps(dir, installation: description))
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
      assert Install.server(opts) == {:ok, running(dir)}

      assert calls.() ==
               server_calls(
                 dir,
                 server_steps(dir,
                   installation:
                     ~s({"name":"trial","provider":"oci","region":"eu-frankfurt-1",) <>
                       ~s("size":"2 OCPUs"})
                 )
               )
    end

    test "writes the pull credential from a file only this user reads, never from an argument",
         %{opts: opts, dir: dir} do
      mock_secret_files()

      assert Install.server(opts) == {:ok, running(dir)}

      assert_received {:secret, "ehos-pull-credential", contents, mode, path}
      assert Bitwise.band(mode, 0o777) == 0o600
      refute File.exists?(path)

      {config, list} =
        contents
        |> Jason.decode!()
        |> get_and_update_in(["items", Access.at(1), "data", ".dockerconfigjson"], &{&1, nil})

      assert list == %{
               "apiVersion" => "v1",
               "kind" => "List",
               "items" => [
                 @namespace_document,
                 %{
                   "apiVersion" => "v1",
                   "kind" => "Secret",
                   "type" => "kubernetes.io/dockerconfigjson",
                   "metadata" => %{"name" => "ehos-pull-credential", "namespace" => "ehos-system"},
                   "data" => %{".dockerconfigjson" => nil}
                 }
               ]
             }

      assert config |> Base.decode64!() |> Jason.decode!() == %{
               "auths" => %{
                 "ghcr.io" => %{
                   "username" => "octocat",
                   "auth" => Base.encode64("octocat:#{@token}")
                 }
               }
             }
    end

    test "never puts the token on a command line", %{opts: opts, dir: dir} do
      calls = record_calls()
      assert Install.server(opts) == {:ok, running(dir)}

      for {_program, args} <- calls.(), arg <- args do
        refute arg =~ @token
        refute arg =~ Base.encode64("octocat:#{@token}")
      end
    end

    test "keeps the credential the cluster holds when no token is given", %{opts: opts, dir: dir} do
      calls = record_calls([{pull_credential_step(), {"secret/ehos-pull-credential\n", 0}}])

      assert Install.server(Keyword.put(opts, :token, "")) == {:ok, running(dir)}

      assert calls.() ==
               server_calls(dir, server_steps(dir, credential: [pull_credential_step()]))
    end

    test "asks the GitHub CLI whose token it is when no user is given", %{opts: opts, dir: dir} do
      calls = record_calls([{{"gh", ["api", "user", "--jq", ".login"]}, {"octocat\n", 0}}])

      assert Install.server(Keyword.put(opts, :username, nil)) == {:ok, running(dir)}

      assert calls.() ==
               server_calls(
                 dir,
                 server_steps(dir,
                   credential: [
                     {"gh", ["api", "user", "--jq", ".login"]} | pull_credential_steps()
                   ]
                 )
               )
    end

    test "takes the login past a notice the GitHub CLI prints after it", %{opts: opts, dir: dir} do
      mock_secret_files([
        {{"gh", ["api", "user", "--jq", ".login"]},
         {"octocat\n\nA new release of gh is available: 2.80.0 → 2.81.0\n", 0}}
      ])

      assert Install.server(Keyword.put(opts, :username, nil)) == {:ok, running(dir)}
      assert_received {:secret, "ehos-pull-credential", contents, _mode, _path}
      %{"items" => [_namespace, secret]} = Jason.decode!(contents)
      config = secret["data"][".dockerconfigjson"] |> Base.decode64!() |> Jason.decode!()

      assert config == %{
               "auths" => %{
                 "ghcr.io" => %{
                   "username" => "octocat",
                   "auth" => Base.encode64("octocat:#{@token}")
                 }
               }
             }
    end

    test "takes the host it is given instead of the tunnel's address", %{opts: opts, dir: dir} do
      # The CA as cert-manager issues it for that host.
      calls =
        record_calls([
          {{:kubectl, ["get", "secret", "ehos-local-ca"]}, {Base.encode64(@example_org_pem), 0}}
        ])

      host = "ehos.example.org"
      assert Install.server(Keyword.put(opts, :host, host)) == {:ok, running(dir, host: host)}
      assert calls.() == server_calls(dir, server_steps(dir, host: host))
    end

    test "rolls CoreDNS out by the rule's hash, the same for the same rule", %{
      opts: opts,
      dir: dir
    } do
      calls = record_calls()
      assert Install.server(opts) == {:ok, running(dir)}
      assert Install.server(opts) == {:ok, running(dir)}
      # Rolled out, never restarted.
      assert calls.() == server_calls(dir, server_steps(dir) ++ server_steps(dir))
    end

    test "waits until a CA that constrains names alone is issued again excluding IP addresses, and says to trust the new one",
         %{opts: opts, dir: dir} do
      test_pid = self()
      # Before the apply, and once after it, the CA is as it was; then it is issued again.
      calls = mock_ca_issued_again(@names_only_pem)

      progress = fn line -> send(test_pid, {:progress, line}) end
      assert Install.server(Keyword.put(opts, :progress, progress)) == {:ok, running(dir)}

      assert for({:progress, line} <- drain(), do: line) ==
               server_progress(
                 ca: [
                   "Creating the installation's CA for #{@host} (local-ca.yaml)",
                   "Waiting for the certificate cert-manager/ehos-local-ca",
                   @issued_again
                 ]
               )

      # Renewed as `cmctl renew` does: its key and name stay, so what it signed still verifies.
      assert calls.() ==
               server_calls(
                 dir,
                 server_steps(dir,
                   ca:
                     ca_steps(:renewed) ++
                       [abandoned_step()] ++ name_steps(@host) ++ [ca_secret_step()]
                 )
               )
    end

    # eh-os D-124: `--host` moved the console, and the CA still permits the old host.
    test "issues the CA again for a host it did not permit, with the same key", %{
      opts: opts,
      dir: dir
    } do
      test_pid = self()
      # Before the apply, and once after it, the CA permits the old host; then it is issued again.
      calls = mock_ca_issued_again(@other_host_pem)

      progress = fn line -> send(test_pid, {:progress, line}) end
      assert Install.server(Keyword.put(opts, :progress, progress)) == {:ok, running(dir)}

      assert for({:progress, line} <- drain(), do: line) ==
               server_progress(
                 ca: [
                   "Creating the installation's CA for #{@host} (local-ca.yaml)",
                   "Waiting for the certificate cert-manager/ehos-local-ca",
                   @issued_again
                 ]
               )

      # Renewed as `cmctl renew` does: its key and name stay, so what it signed still verifies.
      assert calls.() ==
               server_calls(
                 dir,
                 server_steps(dir,
                   ca:
                     ca_steps(:renewed) ++
                       [abandoned_step()] ++ name_steps(@host) ++ [ca_secret_step()]
                 )
               )
    end

    # eh-os#892: on a one-CPU server an application's grants Job was never scheduled.
    test "warns, and goes on, when the nodes have less than two CPUs to allocate", %{
      opts: opts,
      dir: dir
    } do
      for {allocatable, warning} <- [
            {"1", [cpu_warning(1000)]},
            {"1930m", [cpu_warning(1930)]},
            {"2", []},
            {"1 1", []},
            {"", []}
          ] do
        record_calls([
          {{:kubectl, ["get", "nodes", "-o", "jsonpath={.items[*].status.allocatable.cpu}"]},
           {allocatable, 0}}
        ])

        test = self()

        assert Install.server(Keyword.put(opts, :progress, &send(test, {:progress, &1}))) ==
                 {:ok, running(dir)}

        assert for({:progress, line} <- drain(), do: line) == server_progress(checks: warning),
               allocatable
      end
    end

    # eh-os#923, eh-os D-148: on 1.36 a policy made again refused every new environment's pods.
    test "warns, and goes on, when the API server is older than Kubernetes 1.37", %{
      opts: opts,
      dir: dir
    } do
      for {answer, warning} <- [
            {{version_json("1", "36", "v1.36.4+k3s1"), 0}, [kubernetes_warning("v1.36.4+k3s1")]},
            # kubectl's own warnings, before the answer or after it.
            {{"Warning: a line first\n" <> version_json("1", "30+", "v1.30.2-gke.1"), 0},
             [kubernetes_warning("v1.30.2-gke.1")]},
            {{version_json("1", "35", "v1.35.0") <> "\nWarning: a line after\n", 0},
             [kubernetes_warning("v1.35.0")]},
            {{version_json("1", "37", "v1.37.1+k3s1"), 0}, []},
            {{version_json("1", "38", "v1.38.0"), 0}, []},
            {{"not JSON", 0}, []},
            {{"Error from server (Forbidden): forbidden", 1}, []}
          ] do
        record_calls([{version_step(), answer}])
        test = self()

        assert Install.server(Keyword.put(opts, :progress, &send(test, {:progress, &1}))) ==
                 {:ok, running(dir)}

        assert for({:progress, line} <- drain(), do: line) == server_progress(checks: warning),
               inspect(answer)
      end
    end

    test "reads the API server's version from its /version answer" do
      assert Install.server_version(version_json("1", "36", "v1.36.4+k3s1")) ==
               {1, 36, "v1.36.4+k3s1"}

      assert Install.server_version(version_json("1", "27+", "v1.27.3-gke.100")) ==
               {1, 27, "v1.27.3-gke.100"}

      assert Install.server_version(version_json("1", "35", "v1.35.0") <> "\nWarning: after") ==
               {1, 35, "v1.35.0"}

      # Printed, so only what reads as a version.
      assert Install.server_version(version_json("1", "36", "v1.36\e]8;;x\a")) == {1, 36, "1.36"}
      # A credential plugin's line, braces and all, before the answer or after it.
      assert Install.server_version(
               ~s|I1029 exec plugin: {"msg":"cached"}\n| <> version_json("1", "35", "v1.35.0")
             ) == {1, 35, "v1.35.0"}

      assert Install.server_version(version_json("1", "35", "v1.35.0") <> "\nW1029 note {x}\n") ==
               {1, 35, "v1.35.0"}

      # A credential plugin's JSON of its own, on a line before the answer.
      assert Install.server_version(
               ~s|{"level":"info","msg":"token cached"}\n| <> version_json("1", "35", "v1.35.0")
             ) == {1, 35, "v1.35.0"}

      # JSON of its own after the answer; an object shaped like it, but no answer, before it.
      assert Install.server_version(
               version_json("1", "35", "v1.35.0") <> ~s|\n{"level":"info"}\n|
             ) ==
               {1, 35, "v1.35.0"}

      assert Install.server_version(
               ~s|{"major":"x","minor":"y","gitVersion":"vx"}\n| <>
                 version_json("1", "35", "v1.35.0")
             ) == {1, 35, "v1.35.0"}

      assert Install.server_version(
               ~s|{"major":"0","minor":"4"}\n| <> version_json("1", "35", "v1.35.0")
             ) == {1, 35, "v1.35.0"}

      # An answer far larger than `/version`'s is not searched.
      assert Install.server_version(
               String.duplicate(~s|{"level":"info"}\n|, 5_000) <>
                 version_json("1", "35", "v1.35.0")
             ) == nil

      assert Install.server_version(~s|{"major": 1, "minor": "35"}|) == nil
      assert Install.server_version(version_json("1", "x", "v1.x")) == nil
      assert Install.server_version(~s|{"serverVersion": {"major": "1", "minor": "36"}}|) == nil
      assert Install.server_version("") == nil
    end

    test "reads CPU quantities as millicores" do
      assert Install.millicores("2") == 2000
      assert Install.millicores("1930m 4") == 5930
      assert Install.millicores("Warning: a line first\n1") == 1000
      assert Install.millicores("") == nil
      assert Install.millicores("1.5") == nil
    end

    test "refuses the environment given as a map before it runs anything, and says none of it",
         %{opts: opts} do
      mock_nothing_runs()

      assert_raise ArgumentError,
                   ":env must name a module that implements EhosPlatform.Env",
                   fn ->
                     Install.server(Keyword.put(opts, :env, %{"GHCR_TOKEN" => "fixture-token"}))
                   end
    end

    # ehos-tools#543: Keyword.fetch!/2's KeyError would hold every option, the token among them.
    test "refuses a missing :source by its name before it runs anything, and holds none of the options",
         %{opts: opts} do
      mock_nothing_runs()

      error = assert_raise KeyError, fn -> Install.server(Keyword.delete(opts, :source)) end

      assert error == %KeyError{key: :source}
    end

    test "refuses :sleep, which :clock replaced, before it runs anything", %{opts: opts} do
      mock_nothing_runs()

      error =
        assert_raise ArgumentError, fn ->
          Install.server(Keyword.put(opts, :sleep, fn _ms -> :ok end))
        end

      assert Exception.message(error) ==
               ":sleep is no longer taken; give :clock, a module that implements EhosPlatform.Clock"
    end

    # eh-os#846: its Traefik would not serve an older EHOS's console; refused before anything runs.
    test "installs no EHOS before 0.17.0, running nothing", %{opts: opts} do
      calls = record_calls()
      old = %{"version" => "0.16.0", "image" => "i", "chart" => "c"}

      assert Install.server(Keyword.put(opts, :installed, old)) ==
               {:error,
                "EHOS 0.16.0 keeps its console's route where the Traefik this installer installs " <>
                  "no longer reads (eh-os D-117): its console would not answer. Install 0.17.0 " <>
                  "or later. Nothing was changed"}

      assert calls.() == []
    end

    test "keeps the password out of what a failed apply printed", %{opts: opts} do
      password = "s3cret"

      record_calls([
        {secret_apply_step("ehos-smtp"),
         {"error: rejected #{password} (#{Base.encode64(password)})", 1}}
      ])

      mail = %{"from" => "a@b.cd", "smtp" => %{"host" => "h", "port" => 587, "username" => "u"}}

      assert opts
             |> Keyword.put(:mail, mail)
             |> Keyword.put(:smtp_password, password)
             |> Install.server() ==
               {:error,
                "`kubectl` failed with exit status 1:\nerror: rejected [the password] " <>
                  "([the password])"}
    end

    # What runs is recorded before the restart: one that fails leaves the record true, and the
    # Secret marked for the next run.
    test "records what runs before it restarts for a password", %{opts: opts, dir: dir} do
      mail = %{"from" => "a@b.cd", "smtp" => %{"host" => "h", "port" => 587, "username" => "u"}}

      record_calls([
        {{:kubectl, ["rollout", "status", "deployment/ehos-governance"]},
         {"error: timed out waiting for the condition", 1}}
      ])

      assert opts
             |> Keyword.put(:mail, mail)
             |> Keyword.put(:smtp_password, "new")
             |> Install.server() ==
               {:error,
                "`kubectl` failed with exit status 1:\nerror: timed out waiting for the condition"}

      assert dir
             |> Path.join("install.json")
             |> File.read!()
             |> Jason.decode!()
             |> Map.get("digest") == @digest
    end

    test "refuses a password with no user to give it to", %{opts: opts, dir: dir} do
      calls = record_calls()
      mail = %{"from" => "a@b.cd", "smtp" => %{"host" => "h", "port" => 587}}

      assert opts
             |> Keyword.put(:mail, mail)
             |> Keyword.put(:smtp_password, "p")
             |> Install.server() ==
               {:error,
                "SMTP_PASSWORD is set, but no SMTP user is: name the user the password belongs " <>
                  "to, or unset SMTP_PASSWORD. Nothing was changed."}

      # Before anything changes, the pull credential included.
      assert calls.() == server_calls(dir, checked_steps() ++ [console_issuer_step()])
    end

    test "installs nothing when the console's Certificate cannot be read", %{opts: opts, dir: dir} do
      calls =
        record_calls([
          {{:kubectl, console_certificate_step() |> elem(1)},
           {"The connection to the server was refused", 1}}
        ])

      assert Install.server(opts) ==
               {:error,
                "`kubectl` failed with exit status 1:\nThe connection to the server was refused"}

      assert calls.() ==
               server_calls(
                 dir,
                 server_steps(dir,
                   chart: [package_step(), console_certificate_step()],
                   databases: []
                 )
               )
    end

    test "installs nothing when the chart cannot be rendered", %{opts: opts, dir: dir} do
      calls =
        record_calls([
          {{:kubectl, ["get", "certificate"]}, {"ehos-governance-tls=Ingress", 0}},
          {{"helm", ["template", "ehos"]},
           {"Error: template: ehos/templates/governance.yaml: required value", 1}}
        ])

      assert Install.server(opts) ==
               {:error,
                "`helm` failed with exit status 1:\nError: template: " <>
                  "ehos/templates/governance.yaml: required value"}

      assert calls.() ==
               server_calls(
                 dir,
                 server_steps(dir,
                   chart: [
                     package_step(),
                     console_certificate_step(),
                     render_step(ehos_values(dir))
                   ],
                   databases: []
                 )
               )
    end

    test "installs nothing when the console's Certificate cannot be handed over", %{
      opts: opts,
      dir: dir
    } do
      calls =
        record_calls([
          {{:kubectl, ["get", "certificate", "ehos-governance-tls"]},
           {"ehos-governance-tls=Ingress", 0}},
          {{:kubectl, ["patch", "certificate"]}, {"Error from server (Forbidden)", 1}},
          {{"helm", ["template", "ehos"]}, {@chart_with_certificate, 0}}
        ])

      assert Install.server(opts) ==
               {:error, "`kubectl` failed with exit status 1:\nError from server (Forbidden)"}

      assert calls.() ==
               server_calls(
                 dir,
                 server_steps(dir,
                   chart: [
                     package_step(),
                     console_certificate_step(),
                     render_step(ehos_values(dir)),
                     hand_over_step()
                   ],
                   databases: []
                 )
               )
    end

    test "refuses, writing nothing, to switch a server unless told to", %{opts: opts, dir: dir} do
      {opts, calls} = mock_server_with_bundled_traefik(dir, opts, fn _args -> {"", 0} end, 0)

      assert Install.server(Keyword.delete(opts, :switch_traefik)) ==
               {:error,
                "This server runs k3s's Traefik (HelmCharts traefik traefik-crd in kube-system), " <>
                  "and EHOS installs its own (eh-os D-117). Switching it takes the console and " <>
                  "its applications down for a few minutes: run the command again with " <>
                  "--switch-traefik when that suits. Nothing was changed."}

      assert calls.() == server_calls(dir, checked_steps(true))
    end

    test "installs nothing when the switch fails, or k3s's Traefik stays", %{opts: opts, dir: dir} do
      for {ssh, gone_after, polls, said} <- [
            {fn _args -> {"sudo: a password is required", 1} end, 0, 0,
             "Switching the server's Traefik failed with exit status 1:\nsudo: a password is " <>
               "required\nIf /etc/rancher/k3s/config.yaml.d/ehos-traefik.yaml was written, k3s " <>
               "takes its Traefik out at its next restart: run the command again with " <>
               "--switch-traefik to finish, or remove the file over SSH"},
            {fn _args -> {"", 0} end, 1_000, 60,
             "k3s's Traefik was not gone after 60 checks, 5 s apart, since k3s was restarted " <>
               ~s|without it (last: HelmCharts "traefik traefik-crd", CRDs | <>
               ~s|"ingressroutes.traefik.io middlewares.traefik.io "). The console is down until | <>
               "it is. If the cluster does not answer, see on the server `sudo systemctl status " <>
               "k3s` and `sudo journalctl -u k3s`; " <>
               "/etc/rancher/k3s/config.yaml.d/ehos-traefik.yaml is what disables it. Then run " <>
               "the command again, with --switch-traefik"}
          ] do
        {opts, calls} = mock_server_with_bundled_traefik(dir, opts, ssh, gone_after)

        assert Install.server(opts) == {:error, said}

        assert calls.() ==
                 server_calls(
                   dir,
                   checked_steps(true) ++
                     [console_issuer_step()] ++
                     pull_credential_steps() ++ switch_steps(dir, polls)
                 )
      end
    end

    test "says why the server cannot be reached for the switch", %{opts: opts, dir: dir} do
      {opts, calls} = mock_server_with_bundled_traefik(dir, opts, fn _args -> {"", 0} end, 0)

      assert Install.server(Keyword.put(opts, :passphrase, "short")) ==
               {:error,
                "Switching the server reaches it over SSH, as the server's commands do: set " <>
                  "EHOS_STATE_PASSPHRASE to its state's passphrase. Nothing was changed."}

      assert calls.() == server_calls(dir, checked_steps(true))

      # The console's host given, so the record's address is needed for the switch alone.
      File.write!(Path.join(dir, "tunnel.json"), ~s({"port":16443}))

      assert Install.server(Keyword.put(opts, :host, "ehos.example.com")) ==
               {:error, "The tunnel's record names no server address: open the tunnel again"}
    end

    test "installs no Traefik when its chart cannot be pulled, or its CRDs not applied", %{
      opts: opts,
      dir: dir
    } do
      for {failing, answer, said} <- [
            {traefik_pull_step(),
             {"Error: GET \"https://ghcr.io/v2/traefik/helm/traefik\": 502", 1},
             "`helm` failed with exit status 1:\nError: GET " <>
               "\"https://ghcr.io/v2/traefik/helm/traefik\": 502"},
            {traefik_crds_step(),
             {"error: Apply failed with 1 conflict: conflict with \"helm\"", 1},
             "`kubectl` failed with exit status 1:\nerror: Apply failed with 1 conflict: " <>
               "conflict with \"helm\""}
          ] do
        calls = record_calls([{failing, answer}])

        assert Install.server(opts) == {:error, said}

        released =
          release_steps("cnpg") ++
            release_steps("cert-manager") ++
            release_steps("trust-manager") ++ [release_list_step("ehos-ingress", "traefik")]

        traefik =
          if failing == traefik_pull_step(), do: [failing], else: [traefik_pull_step(), failing]

        assert calls.() ==
                 server_calls(
                   dir,
                   checked_steps() ++
                     [console_issuer_step()] ++
                     pull_credential_steps() ++ policy_steps() ++ released ++ traefik
                 )
      end
    end

    test "refuses a release's chart with no GHCR_TOKEN before it changes anything", %{
      opts: opts,
      dir: dir
    } do
      chart = "oci://ghcr.io/empoweredhouse/charts/ehos@" <> @digest

      opts =
        opts
        |> Keyword.put(:source, %EhosPlatform.Source{chart: {:oci, chart}, modules: nil})
        |> Keyword.put(:token, nil)

      calls = record_calls()

      assert Install.server(opts) ==
               {:error,
                "EHOS's image and chart are in private GHCR packages: set GHCR_TOKEN to a " <>
                  "classic GitHub token with read:packages alone (eh-os#218); Helm pulls the " <>
                  "chart with it on every installation"}

      assert calls.() ==
               server_calls(dir, checked_steps() ++ [console_issuer_step()])
    end

    test "says GHCR refused the chart, in words that fit, and nothing for another failure", %{
      opts: opts
    } do
      chart = "oci://ghcr.io/empoweredhouse/charts/ehos@" <> @digest
      opts = Keyword.put(opts, :source, %EhosPlatform.Source{chart: {:oci, chart}, modules: nil})

      for {output, said} <- [
            {~s(GET "https://ghcr.io/token": response status code 403: denied: denied),
             "\nGHCR refused EHOS's chart to GHCR_TOKEN: it needs read:packages, and must not " <>
               "have expired"},
            {~s(GET "https://ghcr.io/v2/x/manifests/sha256:401403": response status code 404: manifest unknown),
             ""},
            {"open /tmp/ca.crt: permission denied", ""}
          ] do
        record_calls([{{"helm", ["pull", chart]}, {"Error: " <> output, 1}}])

        assert Install.server(opts) ==
                 {:error, "`helm` failed with exit status 1:\nError: " <> output <> said}
      end
    end

    test "names the server's command as the caller runs it", %{opts: opts, dir: dir} do
      File.rm!(Path.join(dir, "kubeconfig"))

      assert Install.server(Keyword.put(opts, :server_command, "ehosctl server")) ==
               {:error,
                "#{Path.join(dir, "kubeconfig")} is missing. Open the tunnel first: " <>
                  "`ehosctl server tunnel`"}
    end

    test "keeps the token out of what a failed apply printed", %{opts: opts} do
      record_calls([
        {{:kubectl,
          [
            "apply",
            "--server-side",
            "--force-conflicts",
            "-f",
            tmp("ehos-pull-credential", "secret.json")
          ]}, {"error: the server rejected #{@token}", 1}}
      ])

      assert Install.server(opts) ==
               {:error,
                "`kubectl` failed with exit status 1:\nerror: the server rejected [the token]"}
    end

    test "says how to give a token when there is none, in the cluster or the environment", %{
      opts: opts
    } do
      record_calls([
        {pull_credential_step(),
         {~s|Error from server (NotFound): secrets "ehos-pull-credential" not found|, 1}}
      ])

      assert Install.server(Keyword.put(opts, :token, "")) ==
               {:error,
                "EHOS's image is in a private GHCR package: set GHCR_TOKEN to a classic GitHub " <>
                  "token with read:packages alone (eh-os#218), at least for the first installation"}
    end

    test "stops when the cluster cannot say whether it holds the credential, and installs nothing",
         %{opts: opts, dir: dir} do
      calls =
        record_calls([
          {pull_credential_step(),
           {"The connection to the server 127.0.0.1:16443 was refused", 1}}
        ])

      assert Install.server(Keyword.put(opts, :token, "")) ==
               {:error,
                "kubectl could not say whether ehos-system holds the pull credential " <>
                  "ehos-pull-credential:\nThe connection to the server 127.0.0.1:16443 was refused"}

      assert calls.() ==
               server_calls(
                 dir,
                 checked_steps() ++ [console_issuer_step(), pull_credential_step()]
               )
    end

    test "refuses a digest that is not one", %{opts: opts} do
      assert Install.server(Keyword.put(opts, :digest, nil)) ==
               {:error,
                "Give --digest: the image's index, as `sha256:…`, from the summary of CI's " <>
                  "Publish index job on main"}

      for digest <- ["latest", "sha256:abc", "sha256:" <> String.duplicate("AB", 32)] do
        assert Install.server(Keyword.put(opts, :digest, digest)) ==
                 {:error, "--digest must be sha256: and 64 hex digits, the index CI published"},
               digest
      end
    end

    test "says to open the tunnel when there is no kubeconfig, or no address", %{
      opts: opts,
      dir: dir
    } do
      File.rm!(Path.join(dir, "tunnel.json"))

      assert Install.server(opts) ==
               {:error,
                "The server's address is unknown: open the tunnel first " <>
                  "(`mix ehos.server tunnel`), or give --host"}

      File.rm!(Path.join(dir, "kubeconfig"))

      assert Install.server(opts) ==
               {:error,
                "#{Path.join(dir, "kubeconfig")} is missing. Open the tunnel first: " <>
                  "`mix ehos.server tunnel`"}
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
        assert Install.server(Keyword.put(opts, :host, host)) ==
                 {:error,
                  "--host must be a lowercase DNS name of three labels or more, such as " <>
                    "ehos.example.org"},
               host
      end

      for name <- ["../other", "Trial", "a,b", "trial\n"] do
        assert Install.server(Keyword.put(opts, :name, name)) ==
                 {:error,
                  "The installation's name is 2 to 16 lowercase letters, digits and hyphens"},
               name
      end
    end

    test "says so when the CA is not issued again within a minute", %{opts: opts} do
      record_calls([
        {{:kubectl, ["get", "secret", "ehos-local-ca"]}, {Base.encode64(@names_only_pem), 0}}
      ])

      assert Install.server(opts) ==
               {:error,
                "The CA ehos-local-ca was not issued again for #{@host} within a minute: see " <>
                  "`kubectl describe certificate ehos-local-ca -n cert-manager`"}
    end

    test "says to open the tunnel when the cluster does not answer", %{opts: opts} do
      record_calls([
        {{:kubectl, ["get", "nodes"]},
         {"The connection to the server 127.0.0.1:16443 was refused", 1}}
      ])

      assert Install.server(opts) ==
               {:error,
                "The cluster does not answer through the tunnel (exit status 1). Open it with " <>
                  "`mix ehos.server tunnel`:\nThe connection to the server 127.0.0.1:16443 was " <>
                  "refused"}
    end
  end

  # eh-os D-158 (eh-os#1236).
  @rendered_issuers """
  kind: ClusterIssuer
  metadata:
    name: ehos-acme-console
  ---
  kind: ClusterIssuer
  metadata:
    name: ehos-acme-addresses
  """
  describe "server/1 with public certificates" do
    @public_host "ehos.client.example"
    @challenge "4f2c._acme-dns.ehos.client.example"
    @console_account "https://acme-v02.api.letsencrypt.org/acme/acct/1"
    @addresses_account "https://acme-v02.api.letsencrypt.org/acme/acct/2"

    # The records' values the installer gives the chart, as the chart names them (eh-os D-162).
    @public_records %{
      "address" => "152.70.8.238",
      "challenge" => @challenge,
      "consoleAccount" => @console_account,
      "addressesAccount" => @addresses_account
    }

    setup %{tmp_dir: tmp_dir} do
      home = Path.join(tmp_dir, "ehos")
      dir = Path.join(home, "trial")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "kubeconfig"), "{}")
      File.write!(Path.join(dir, "tunnel.json"), ~s({"address":"152.70.8.238","port":16443}))
      File.write!(Path.join(dir, "server.tfvars.json"), ~s({"public_certificates":true}))

      opts = [
        runner: CommandRunnerMock,
        source: @source,
        home: home,
        digest: @digest,
        token: @token,
        username: "octocat",
        env: EnvMock,
        clock: ClockMock,
        host: @public_host,
        public_certificates: true,
        dns: DnsMock,
        certificate_log: CertificateLogMock
      ]

      stub(EnvMock, :get, fn _name -> nil end)
      stub(EnvMock, :user_home, fn -> @system_home end)
      stub(ClockMock, :sleep, fn _ms -> :ok end)
      stub(CertificateLogMock, :certificates, fn _name -> {:ok, []} end)
      stub_now()

      %{opts: opts, dir: dir}
    end

    test "refuses a host under sslip.io, or one that is a registered domain, before it changes anything",
         %{opts: opts, dir: dir} do
      for {host, refusal} <- [
            {"ehos.152-70-8-238.sslip.io",
             "--public-certificates needs a host of your company's own, with --host: Let's " <>
               "Encrypt does not issue certificates for ehos.152-70-8-238.sslip.io. Nothing was " <>
               "changed"},
            {"client.co.uk",
             "client.co.uk is a registered domain: the cluster would then send every name of " <>
               "your company to the server. Give a host under it, such as ehos.client.co.uk. " <>
               "Nothing was changed"}
          ] do
        calls = public_calls(issuer: "")

        assert Install.server(Keyword.put(opts, :host, host)) == {:error, refusal}
        assert calls.() == server_calls(dir, checked_steps() ++ [console_issuer_step()])
      end
    end

    test "refuses a server whose port 53 up did not open", %{opts: opts, dir: dir} do
      File.write!(Path.join(dir, "server.tfvars.json"), ~s({"name":"trial"}))
      calls = public_calls(issuer: "")

      assert Install.server(opts) ==
               {:error,
                "Port 53 of the server is closed, and Let's Encrypt asks acme-dns there for " <>
                  "the console's certificate: run `mix ehos.server up --public-certificates` " <>
                  "first. Nothing was changed"}

      assert calls.() == server_calls(dir, checked_steps() ++ [console_issuer_step()])
    end

    # kubectl can warn after the value, and the runner merges its stderr into the output.
    test "reads the console's issuer past a warning kubectl prints after it, or alone", %{
      opts: opts,
      dir: dir
    } do
      warning = "W1105 13:00:00.000 memcache.go:265] couldn't get current server API group list"

      calls = public_calls(issuer: "ehos-acme-console ehos.old.example\n" <> warning, held: true)
      assert {:error, "EHOS runs at ehos.old.example with public" <> _} = Install.server(opts)

      assert calls.() ==
               server_calls(
                 dir,
                 checked_steps() ++
                   [
                     console_issuer_step(),
                     console_certificate_read_step(),
                     public_certificate_read_step()
                   ]
               )

      public_calls(issuer: warning)
      File.write!(Path.join(dir, "server.tfvars.json"), ~s({"name":"trial"}))
      assert {:error, "Port 53 of the server is closed" <> _} = Install.server(opts)
    end

    test "refuses to move an installation with public certificates to another host", %{
      opts: opts,
      dir: dir
    } do
      calls = public_calls(issuer: "ehos-acme-console ehos.old.example", held: true)

      assert Install.server(opts) ==
               {:error,
                "EHOS runs at ehos.old.example with public certificates. It cannot move to " <>
                  "ehos.client.example yet: give --host ehos.old.example. Nothing was changed"}

      assert calls.() ==
               server_calls(
                 dir,
                 checked_steps() ++
                   [
                     console_issuer_step(),
                     console_certificate_read_step(),
                     public_certificate_read_step()
                   ]
               )
    end

    test "moves an installation under its own CA: the console's certificate for the new host first, then the chart, then the CA removed",
         %{opts: opts, dir: dir} do
      File.write!(Path.join(dir, "ca.crt"), "the installation's CA")
      calls = move_calls()
      serve_zone(public_zone())

      assert {:ok, message} = Install.server(opts)

      assert message =~ "EHOS is running at https://ehos.client.example"

      assert message =~
               "EHOS moved from ehos.152-70-8-238.sslip.io. Each person must sign in again"

      assert File.read!(Path.join(dir, "ca.crt")) == File.read!(PublicCertificates.roots())

      # D-158's order: the policy and the issuers, the console's certificate for the new host,
      # issued and its Certificate deleted with its Secret kept; only then CoreDNS's rule and the
      # chart; then the installation's CA; then the addresses.
      assert moved_steps(calls.()) == [
               {"kubectl", ["get", "ehosdeployments.ehos.empowered.house", "-A"]},
               {"kubectl", ["get", "certificates.cert-manager.io", "-n", "ehos-addresses"]},
               {"kubectl",
                ["apply", "--server-side", "--field-manager=helm", "ehos-acme-issuers"]},
               {"kubectl",
                [
                  "apply",
                  "--server-side",
                  "--field-manager=helm",
                  "ehos-acme-console",
                  "ehos-acme-addresses"
                ]},
               {"kubectl",
                ["apply", "--server-side", "--field-manager=helm", "ehos-acme-console"]},
               {"kubectl",
                ["apply", "--server-side", "--field-manager=helm", "ehos-acme-addresses"]},
               {"kubectl",
                ["apply", "--server-side", "--field-manager=helm", "ehos-governance-public-tls"]},
               {"kubectl",
                [
                  "wait",
                  "--for=condition=Ready",
                  "certificate/ehos-governance-public-tls",
                  "-n",
                  "ehos-system",
                  "--timeout=600s"
                ]},
               {"kubectl",
                [
                  "delete",
                  "certificate",
                  "ehos-governance-public-tls",
                  "-n",
                  "ehos-system",
                  "--ignore-not-found",
                  "--cascade=orphan"
                ]},
               {"kubectl", ["apply", "-f", "coredns-custom.yaml"]},
               {"helm", ["upgrade", "--install", "ehos"]},
               {"kubectl",
                [
                  "wait",
                  "--for=condition=Ready",
                  "certificate/ehos-governance-public-tls",
                  "-n",
                  "ehos-system",
                  "--timeout=10m"
                ]},
               {"kubectl", ["delete", "clusterissuer/ehos-local-ca", "--ignore-not-found"]},
               {"kubectl", ["get", "certificates.cert-manager.io", "-n", "ehos-addresses"]}
             ]

      {"helm", upgrade} =
        Enum.find(calls.(), &match?({"helm", ["upgrade", "--install", "ehos" | _]}, &1))

      assert "governance.host=ehos.client.example" in upgrade
      assert "governance.ingress.tls.secretName=ehos-governance-public-tls" in upgrade
      assert "publicCertificates.enabled=true" in upgrade
    end

    # ehos-tools#839: a run stopped after the chart leaves the record naming the host that answers.
    test "records the new host as soon as the chart serves it, when the move stops after the chart",
         %{opts: opts, dir: dir} do
      File.write!(Path.join(dir, "ca.crt"), "the installation's CA")

      File.write!(
        Path.join(dir, "install.json"),
        ~s({"digest":"#{@digest}","host":"ehos.152-70-8-238.sslip.io"})
      )

      calls =
        move_calls(fn
          # The first read of own_authority_removed/1, after the chart.
          [
            "get",
            "certificate",
            "ehos-governance-tls",
            "-n",
            "ehos-system",
            "--ignore-not-found",
            "-o",
            "jsonpath={.spec.issuerRef.name}" | _
          ] ->
            {"The connection to the server was refused", 1}

          _other ->
            nil
        end)

      serve_zone(public_zone())

      assert Install.server(opts) ==
               {:error,
                "`kubectl` failed with exit status 1:\nThe connection to the server was refused"}

      assert {"helm", ["upgrade", "--install", "ehos"]} in moved_steps(calls.())

      assert dir |> Path.join("install.json") |> File.read!() |> Jason.decode!() == %{
               "digest" => @digest,
               "host" => @public_host,
               "repository" => "ghcr.io/empoweredhouse/ehos"
             }

      assert File.read!(Path.join(dir, "ca.crt")) == File.read!(PublicCertificates.roots())
    end

    # ehos-tools#827: a server made from EHOS before 0.27.0 keeps port 53 closed, though `up` was
    # given --public-certificates, which server.tfvars.json records.
    test "refuses before anything waits when acme-dns does not answer on the server's port 53",
         %{opts: opts} do
      for {calls, unchanged} <- [
            {fn -> public_calls(issuer: "") end, "EHOS is not installed yet"},
            {fn -> move_calls() end,
             "EHOS did not move, and still answers at ehos.152-70-8-238.sslip.io"}
          ] do
        calls = calls.()
        serve_zone(public_zone(), port_53: :closed)

        assert Install.server(opts) ==
                 {:error,
                  "acme-dns does not answer on port 53 of the server, 152.70.8.238 (no answer " <>
                    "(:timeout)), and Let's Encrypt asks it there for the console's " <>
                    "certificate. A server made from an EHOS release before 0.27.0 keeps port " <>
                    "53 closed, also when it was given --public-certificates. Run `mix " <>
                    "ehos.server up --public-certificates` from EHOS 0.27.0 or later, then run " <>
                    "this command again. " <> unchanged}

        steps = Enum.map(calls.(), fn {program, args} -> {program, step(args)} end)

        refute Enum.any?(
                 steps,
                 &match?(
                   {"kubectl", ["wait", _, "certificate/ehos-governance-public-tls" | _]},
                   &1
                 )
               )

        refute Enum.any?(steps, &match?({"helm", ["upgrade", "--install", "ehos" | _]}, &1))
      end
    end

    test "upgrades an installation that has them while port 53 does not answer, and warns of it",
         %{opts: opts} do
      public_calls(issuer: "ehos-acme-console ehos.client.example", held: true)
      serve_zone(public_zone(), port_53: :closed)
      test = self()

      assert {:ok, _message} =
               opts
               |> Keyword.put(:progress, &send(test, {:progress, &1}))
               |> Install.server()

      progress = for {:progress, line} <- drain(), do: line

      assert ("Warning: acme-dns does not answer on port 53 of the server, 152.70.8.238 (no " <>
                "answer (:timeout)), so Let's Encrypt cannot renew the console's certificate. " <>
                "Check that the server's firewall lets DNS in over UDP and TCP") in progress
    end

    test "makes acme-dns, the accounts and the issuers' policy for the new host, and changes nothing the installation uses while a record is missing",
         %{opts: opts, dir: dir} do
      File.write!(Path.join(dir, "ca.crt"), "the installation's CA")
      calls = move_calls()
      serve_zone(%{})

      assert {:error, message} = Install.server(opts)

      assert message =~
               "EHOS did not move, and still answers at ehos.152-70-8-238.sslip.io. acme-dns " <>
                 "and the two Let's Encrypt accounts are ready. Make these DNS records for " <>
                 "ehos.client.example, then run this command again:\n"

      assert File.read!(Path.join(dir, "ca.crt")) == "the installation's CA"

      assert moved_steps(calls.()) == [
               {"kubectl", ["get", "ehosdeployments.ehos.empowered.house", "-A"]},
               {"kubectl", ["get", "certificates.cert-manager.io", "-n", "ehos-addresses"]},
               {"kubectl",
                ["apply", "--server-side", "--field-manager=helm", "ehos-acme-issuers"]},
               {"kubectl",
                [
                  "apply",
                  "--server-side",
                  "--field-manager=helm",
                  "ehos-acme-console",
                  "ehos-acme-addresses"
                ]},
               {"kubectl",
                ["apply", "--server-side", "--field-manager=helm", "ehos-acme-console"]},
               {"kubectl",
                ["apply", "--server-side", "--field-manager=helm", "ehos-acme-addresses"]}
             ]
    end

    test "leaves the old host serving when the console's certificate for the new host is not issued",
         %{opts: opts, dir: dir} do
      File.write!(Path.join(dir, "ca.crt"), "the installation's CA")

      calls =
        move_calls(fn
          ["wait", "--for=condition=Ready", "certificate/ehos-governance-public-tls" | _] ->
            {"error: timed out waiting for the condition", 1}

          ["get", "certificate", "ehos-governance-public-tls" | _] ->
            {"Issuing certificate as Secret does not exist\nW1106 10:00:00 a warning after it\n",
             0}

          _other ->
            nil
        end)

      serve_zone(public_zone())

      assert Install.server(opts) ==
               {:error,
                "Let's Encrypt did not issue the certificate of the console for " <>
                  "ehos.client.example in 10 minutes. The installation did not move, and still " <>
                  "answers at its old host. cert-manager says: Issuing certificate as Secret " <>
                  "does not exist. Check the DNS records, then run the command again"}

      assert File.read!(Path.join(dir, "ca.crt")) == "the installation's CA"

      assert moved_steps(calls.()) |> Enum.drop(6) == [
               {"kubectl",
                ["apply", "--server-side", "--field-manager=helm", "ehos-governance-public-tls"]},
               {"kubectl",
                [
                  "wait",
                  "--for=condition=Ready",
                  "certificate/ehos-governance-public-tls",
                  "-n",
                  "ehos-system",
                  "--timeout=600s"
                ]},
               {"kubectl",
                [
                  "delete",
                  "certificate",
                  "ehos-governance-public-tls",
                  "-n",
                  "ehos-system",
                  "--ignore-not-found",
                  "--cascade=background"
                ]}
             ]
    end

    test "moves an installation under its own CA at the host it is given without saying it moved",
         %{opts: opts} do
      move_calls(fn
        ["get", "certificates.cert-manager.io", "ehos-governance-tls" | _] ->
          {"ehos-local-ca ehos.client.example", 0}

        _other ->
          nil
      end)

      serve_zone(public_zone())

      assert {:ok, message} = Install.server(opts)
      assert message =~ "Its certificate is from Let's Encrypt"

      assert String.ends_with?(
               message,
               " Give each pipeline this ca.crt as EHOSCTL_CA_FILE: the installation's CA no " <>
                 "longer verifies the console."
             )

      refute message =~ "moved from"
    end

    test "keeps what the operator trusts when the chart is not installed at the new host",
         %{opts: opts, dir: dir} do
      File.write!(Path.join(dir, "ca.crt"), "the installation's CA")

      move_calls(fn _step -> nil end, fn
        ["upgrade", "--install", "ehos" | _] -> {"Error: the registry did not answer", 1}
        _args -> nil
      end)

      serve_zone(public_zone())

      assert Install.server(opts) ==
               {:error, "`helm` failed with exit status 1:\nError: the registry did not answer"}

      assert File.read!(Path.join(dir, "ca.crt")) == "the installation's CA"
    end

    test "refuses to move an installation while a domain is mapped, before it changes anything",
         %{opts: opts} do
      calls =
        move_calls(fn
          ["get", "ehosdeployments.ehos.empowered.house" | _] ->
            {"ehos-env-production/ledger=ledger.client.example\nehos-env-production/journal=\n",
             0}

          _other ->
            nil
        end)

      assert Install.server(opts) ==
               {:error,
                "A domain is mapped to an application: ledger.client.example " <>
                  "(ehos-env-production/ledger). If the installation moves, that domain stops " <>
                  "answering. Remove each mapping, then run the command again. Nothing was " <>
                  "changed"}

      assert moved_steps(calls.()) == [
               {"kubectl", ["get", "ehosdeployments.ehos.empowered.house", "-A"]}
             ]
    end

    test "refuses to move an installation whose addresses need more certificates than Let's Encrypt issues in a week",
         %{opts: opts} do
      move_calls(fn
        ["get", "certificates.cert-manager.io", "-n", "ehos-addresses" | _] ->
          {Enum.map_join(1..50, "\n", &"ehos-tls-a#{&1}"), 0}

        _other ->
          nil
      end)

      assert Install.server(opts) ==
               {:error,
                "The move needs 51 certificates from Let's Encrypt: 1 for the console and 1 for " <>
                  "each address of an application. Let's Encrypt issues at most 50 certificates " <>
                  "in a week for one registered domain, and the other certificates of your " <>
                  "company count too. Remove ephemeral environments until the move needs 50 or " <>
                  "fewer. Nothing was changed"}
    end

    test "refuses an installation whose console's certificate another issuer signs", %{
      opts: opts
    } do
      public_calls(issuer: "letsencrypt-prod ehos.152-70-8-238.sslip.io")

      assert Install.server(opts) ==
               {:error,
                "The console's certificate is issued by letsencrypt-prod, which this installer " <>
                  "did not make, so it cannot move the installation to public certificates. " <>
                  "Nothing was changed"}
    end

    test "makes acme-dns and the accounts, then says the records and installs nothing while one is missing",
         %{opts: opts} do
      calls = public_calls(issuer: "")
      serve_zone(%{})

      assert {:error, message} = Install.server(opts)

      assert message =~
               "EHOS is not installed yet. acme-dns and the two Let's Encrypt accounts are " <>
                 "ready. Make these DNS records for ehos.client.example, then run this command " <>
                 "again:\n  ehos.client.example "

      assert message =~ "_acme-challenge.ehos.client.example  CNAME  #{@challenge}."
      assert message =~ "accounturi=#{@console_account}; validationmethods=dns-01"
      assert message =~ "accounturi=#{@addresses_account}; validationmethods=http-01"

      assert message =~
               "What your name servers answer now:\n  - ehos.client.example has no A record"

      steps = Enum.map(calls.(), fn {program, args} -> {program, step(args)} end)

      # No installation CA, no chart installed; the issuers made from the chart rendered.
      refute Enum.any?(
               steps,
               &(match?({"kubectl", ["apply", "-f", _local_ca]}, &1) and
                   String.ends_with?(elem(&1, 1) |> List.last(), "local-ca.yaml"))
             )

      refute Enum.any?(steps, &match?({"helm", ["upgrade", "--install", "ehos" | _]}, &1))
      assert Enum.any?(steps, &match?({"helm", ["template", "ehos" | _]}, &1))

      assert Enum.any?(
               steps,
               &match?(
                 {"kubectl", ["exec", "-n", "ehos-acme-dns", "deployment/acme-dns" | _]},
                 &1
               )
             )

      # acme-dns's image is in a private package: its namespace gets the credential.
      assert Enum.any?(
               steps,
               &match?(
                 {"kubectl",
                  ["annotate", "secret", "ehos-pull-credential", "-n", "ehos-acme-dns" | _]},
                 &1
               )
             )
    end

    test "installs the chart with the ACME issuers and Let's Encrypt's roots once each record is right",
         %{opts: opts, dir: dir} do
      calls = public_calls(issuer: "")
      serve_zone(public_zone())
      test = self()

      assert {:ok, message} =
               Install.server(Keyword.put(opts, :progress, &send(test, {:progress, &1})))

      assert message =~ "Its certificate is from Let's Encrypt"
      assert File.read!(Path.join(dir, "ca.crt")) == File.read!(PublicCertificates.roots())

      {"helm", upgrade} =
        Enum.find(calls.(), &match?({"helm", ["upgrade", "--install", "ehos" | _]}, &1))

      for value <- [
            "governance.ingress.annotations.cert-manager\\.io/cluster-issuer=ehos-acme-console",
            "environments.ingress.annotations.cert-manager\\.io/cluster-issuer=ehos-acme-addresses",
            "environments.caCertificate=#{PublicCertificates.roots()}",
            "governance.ingress.tls.secretName=ehos-governance-public-tls",
            "publicCertificates.enabled=true",
            "publicCertificates.addresses.solverImage=quay.io/jetstack/cert-manager-acmesolver@" <>
              "sha256:699b40d622211ab7accad8a21b04c5fbaa1841ef7a12621e8de492dbe27b2503"
          ],
          do: assert(value in upgrade, value)

      # eh-os D-162: the values it checked, which the governance plane checks each day.
      assert records(upgrade) == @public_records

      assert {"kubectl", _wait} =
               Enum.find(
                 calls.(),
                 &match?(
                   {"kubectl",
                    [
                      _,
                      _,
                      _,
                      _,
                      "wait",
                      "--for=condition=Ready",
                      "certificate/ehos-governance-public-tls",
                      "-n",
                      "ehos-system",
                      "--timeout=10m"
                    ]},
                   &1
                 )
               )

      progress = for {:progress, line} <- drain(), do: line
      assert "The DNS records for ehos.client.example are in place" in progress
      assert Enum.any?(progress, &String.starts_with?(&1, "Warning: A record of your own under"))
    end

    # eh-os D-155, ehos-tools#853: as JSON, beside the ACME issuers that certify a mapped domain.
    test "gives the chart the allowed domains with public certificates", %{opts: opts} do
      calls = public_calls(issuer: "")
      serve_zone(public_zone())

      assert {:ok, _message} =
               opts
               |> Keyword.put(:allowed_domains, ["client.example", "client.co.uk"])
               |> Install.server()

      {"helm", upgrade} =
        Enum.find(calls.(), &match?({"helm", ["upgrade", "--install", "ehos" | _]}, &1))

      assert ~s(environments.domains.allowed=["client.example","client.co.uk"]) in upgrade
    end

    # eh-os D-155: the Public Suffix List, its private section, a wildcard and an exception; the
    # console's host; the chart's form. Refused before the cluster is asked anything.
    test "refuses an allowed domain that is a public suffix, the console's host or not a domain name, before it changes anything",
         %{opts: opts, dir: dir} do
      for {domain, refusal} <- [
            {"co.uk", public_suffix("co.uk")},
            {"github.io", public_suffix("github.io")},
            {"anything.ck", public_suffix("anything.ck")},
            {"ehos.client.example",
             "ehos.client.example is the console's host or a name under it, " <>
               "ehos.client.example, which no mapping may claim. Give a domain of your company " <>
               "outside it. Nothing was changed"},
            {"edge.ehos.client.example",
             "edge.ehos.client.example is the console's host or a name under it, " <>
               "ehos.client.example, which no mapping may claim. Give a domain of your company " <>
               "outside it. Nothing was changed"},
            {"Client.example", not_a_domain(~s("Client.example"))},
            {"client", not_a_domain(~s("client"))}
          ] do
        calls = public_calls(issuer: "")

        assert Install.server(Keyword.put(opts, :allowed_domains, ["client.example", domain])) ==
                 {:error, refusal}

        assert calls.() == server_calls(dir, [])
      end

      # An exception to the wildcard *.ck is a registered domain, as is a name under a suffix.
      public_calls(issuer: "")
      serve_zone(public_zone())

      assert {:ok, _message} =
               Install.server(Keyword.put(opts, :allowed_domains, ["www.ck", "client.github.io"]))
    end

    test "keeps public certificates on an installation that has them, given or not, and warns of a record that changed",
         %{opts: opts} do
      calls = public_calls(issuer: "ehos-acme-console ehos.client.example", held: true)
      serve_zone(Map.delete(public_zone(), {@public_host, :caa}))
      test = self()

      assert {:ok, _message} =
               opts
               |> Keyword.delete(:public_certificates)
               |> Keyword.put(:progress, &send(test, {:progress, &1}))
               |> Install.server()

      steps = Enum.map(calls.(), fn {program, args} -> {program, step(args)} end)

      # The account and both keys reused, nothing registered, the chart not rendered for issuers.
      refute Enum.any?(steps, &match?({"kubectl", ["exec" | _]}, &1))
      refute Enum.any?(steps, &match?({"helm", ["template" | _]}, &1))

      refute Enum.any?(
               steps,
               &match?(
                 {"kubectl", ["annotate", "secret", "ehos-acme-" <> _, "-n", "cert-manager" | _]},
                 &1
               )
             )

      {"helm", upgrade} =
        Enum.find(calls.(), &match?({"helm", ["upgrade", "--install", "ehos" | _]}, &1))

      assert "publicCertificates.enabled=true" in upgrade

      assert "governance.ingress.annotations.cert-manager\\.io/cluster-issuer=ehos-acme-console" in upgrade

      # The values it made the records from, not what the name servers answer.
      assert records(upgrade) == @public_records

      progress = for {:progress, line} <- drain(), do: line

      assert Enum.any?(
               progress,
               &String.starts_with?(
                 &1,
                 "Warning: the DNS records changed: ehos.client.example has no CAA record"
               )
             )
    end

    test "upgrades an installation that has them while acme-dns does not answer, and says so",
         %{opts: opts} do
      calls =
        record_calls(fn
          "kubectl", args ->
            case step(args) do
              ["rollout", "status", "deployment/acme-dns" | _] ->
                {"error: timed out waiting for the condition", 1}

              other ->
                public_answer(other, %{
                  issuer: "ehos-acme-console ehos.client.example",
                  held?: true
                })
            end

          "helm", ["get", "values", "ehos" | _] ->
            {Jason.encode!(%{"publicCertificates" => %{"records" => @public_records}}), 0}

          _program, _args ->
            nil
        end)

      expect(DnsMock, :query, 0, fn _name, _type, _server -> {:error, "unused"} end)
      expect(CertificateLogMock, :certificates, 0, fn _name -> {:ok, []} end)
      test = self()

      assert {:ok, _message} =
               opts
               |> Keyword.put(:progress, &send(test, {:progress, &1}))
               |> Install.server()

      progress = for {:progress, line} <- drain(), do: line

      assert Enum.any?(
               progress,
               &String.starts_with?(
                 &1,
                 "Warning: acme-dns or a Let's Encrypt account is not ready, so the DNS records were not checked"
               )
             )

      # eh-os D-162: the release's values are kept, since the chart is installed anew.
      {"helm", upgrade} =
        Enum.find(calls.(), &match?({"helm", ["upgrade", "--install", "ehos" | _]}, &1))

      assert records(upgrade) == @public_records
    end

    test "refuses a first install while acme-dns does not answer", %{opts: opts} do
      record_calls(fn
        "kubectl", args ->
          case step(args) do
            ["rollout", "status", "deployment/acme-dns" | _] -> {"timed out", 1}
            other -> public_answer(other, %{issuer: "", held?: false})
          end

        _program, _args ->
          nil
      end)

      # Every rollout fails, the one that would close registration again too, which is said.
      assert Install.server(opts) ==
               {:error,
                "`kubectl` failed with exit status 1:\ntimed out\nacme-dns's registration may " <>
                  "still be open: run the command again to close it"}
    end

    test "reads the Certificate Transparency logs on a first install alone", %{opts: opts} do
      public_calls(issuer: "ehos-acme-console ehos.client.example", held: true)
      serve_zone(public_zone())
      expect(CertificateLogMock, :certificates, 0, fn _name -> {:ok, []} end)

      assert {:ok, _message} = Install.server(opts)
    end
  end

  # The cluster as the public certificates' steps find it: the console's Certificate with `issuer`
  # ("" for none), and, `held`, acme-dns's account, both keys and both issuers there already.
  @public_account %{"fulldomain" => @challenge, "username" => "u", "password" => "p"}

  defp records(upgrade) do
    Enum.find_value(upgrade, fn
      "publicCertificates.records=" <> json -> Jason.decode!(json)
      _other -> nil
    end)
  end

  defp public_suffix(domain),
    do:
      "#{domain} is on the Public Suffix List: names under it belong to many owners, not to " <>
        "your company. Give a domain that your company registered, such as " <>
        "client.#{domain}. Nothing was changed"

  defp not_a_domain(shown),
    do:
      "#{shown} is not a domain that can be allowed. Give a domain name in lowercase, of at " <>
        "least two labels and at most 200 characters, such as client.example. Give an " <>
        "internationalized name as its A-label (xn--…). Nothing was changed"

  defp public_calls(opts) do
    cluster = %{issuer: Keyword.fetch!(opts, :issuer), held?: Keyword.get(opts, :held, false)}

    record_calls(fn
      "kubectl", args -> public_answer(step(args), cluster)
      "helm", ["template" | _] -> {@rendered_issuers, 0}
      _program, _args -> nil
    end)
  end

  # The chart rendered for a move: the issuers, their policy and binding, and the console's
  # Certificate for the new host.
  @rendered_move @rendered_issuers <>
                   """
                   ---
                   kind: ValidatingAdmissionPolicy
                   metadata:
                     name: ehos-acme-issuers
                   ---
                   kind: ValidatingAdmissionPolicyBinding
                   metadata:
                     name: ehos-acme-issuers
                   ---
                   kind: Certificate
                   metadata:
                     name: ehos-governance-public-tls
                     namespace: ehos-system
                   spec:
                     dnsNames: [ehos.client.example]
                   """

  # An installation that runs under its own CA at sslip.io, with no domain mapped and no address,
  # asked to move to ehos.client.example; `override` answers a kubectl step first.
  defp move_calls(override \\ fn _step -> nil end, helm \\ fn _args -> nil end) do
    cluster = %{issuer: "ehos-local-ca ehos.152-70-8-238.sslip.io", held?: false}
    {:ok, applied} = Agent.start_link(fn -> [] end)

    calls =
      record_calls(fn
        "kubectl", args ->
          kept(applied, step(args))
          override.(step(args)) || public_answer(step(args), cluster)

        "helm", ["template" | _] ->
          {@rendered_move, 0}

        "helm", args ->
          helm.(args)

        _program, _args ->
          nil
      end)

    # What each server-side apply held, read while its file is there, in the order applied.
    fn ->
      names = applied |> Agent.get(& &1) |> Enum.reverse()

      calls.() |> Enum.map_reduce(names, &with_applied/2) |> elem(0)
    end
  end

  defp with_applied({"kubectl", args} = call, [held | rest] = names) do
    if match?(["apply", "--server-side", "--field-manager=helm" | _], step(args)),
      do: {{"kubectl", ["apply", "--server-side", "--field-manager=helm" | held]}, rest},
      else: {call, names}
  end

  defp with_applied(call, names), do: {call, names}

  defp kept(applied, ["apply", "--server-side", "--field-manager=helm", "-f", path]) do
    held = Jason.decode!(File.read!(path))

    names =
      for %{"metadata" => %{"name" => name}} <- held["items"] || [held], uniq: true, do: name

    Agent.update(applied, &[names | &1])
  end

  defp kept(_applied, _step), do: :ok

  # The steps of a move that matter to its order, each cut to what tells it apart: an applied
  # file by the names it holds, CoreDNS's rule by its file.
  defp moved_steps(calls) do
    for {program, args} <- calls,
        moved = moved_step(program, step(args)),
        do: moved
  end

  defp moved_step("kubectl", ["get", "ehosdeployments.ehos.empowered.house", "-A" | _]),
    do: {"kubectl", ["get", "ehosdeployments.ehos.empowered.house", "-A"]}

  defp moved_step("kubectl", ["get", "certificates.cert-manager.io", "-n", "ehos-addresses" | _]),
    do: {"kubectl", ["get", "certificates.cert-manager.io", "-n", "ehos-addresses"]}

  defp moved_step("kubectl", ["apply", "--server-side", "--field-manager=helm" | _names] = args),
    do: {"kubectl", args}

  defp moved_step("kubectl", ["apply", "-f", path]) do
    if String.ends_with?(path, "coredns-custom.yaml"),
      do: {"kubectl", ["apply", "-f", "coredns-custom.yaml"]}
  end

  defp moved_step(
         "kubectl",
         ["wait", "--for=condition=Ready", "certificate/ehos-governance-public-tls" | _] = args
       ),
       do: {"kubectl", args}

  defp moved_step("kubectl", ["delete", "certificate", "ehos-governance-public-tls" | _] = args),
    do: {"kubectl", args}

  defp moved_step("kubectl", ["delete", "clusterissuer/ehos-local-ca" | _] = args),
    do: {"kubectl", args}

  defp moved_step("helm", ["upgrade", "--install", "ehos" | _]),
    do: {"helm", ["upgrade", "--install", "ehos"]}

  defp moved_step(_program, _args), do: nil

  defp public_answer(["get", "crd", "certificates.cert-manager.io" | _], %{issuer: ""}),
    do: {"", 0}

  defp public_answer(["get", "crd", "certificates.cert-manager.io" | _], _cluster),
    do: {@certificate_crd, 0}

  # The console's Certificate is the installation's CA's under one name, the ACME issuer's under
  # another (eh-os#1301).
  defp public_answer(["get", "certificates.cert-manager.io", "ehos-governance-tls" | _], cluster),
    do: {if(String.contains?(cluster.issuer, "ehos-local-ca"), do: cluster.issuer, else: ""), 0}

  defp public_answer(
         ["get", "certificates.cert-manager.io", "ehos-governance-public-tls" | _],
         cluster
       ),
       do:
         {if(String.contains?(cluster.issuer, "ehos-local-ca"), do: "", else: cluster.issuer), 0}

  defp public_answer(["get", "secret", "ehos-acme-dns" | _], %{held?: true}),
    do: {%{@public_host => @public_account} |> Jason.encode!() |> Base.encode64(), 0}

  defp public_answer(["get", kind, "ehos-acme-" <> _ = name | rest], %{held?: true})
       when kind in ["secret", "clusterissuer"] and rest != ["-o", "jsonpath={.status.acme.uri}"],
       do: {"#{kind}/#{name}", 0}

  defp public_answer(["get", "nodes", "-o", "jsonpath={.items[*].spec.podCIDRs[*]}"], _cluster),
    do: {"10.42.0.0/24", 0}

  defp public_answer(["exec" | _], _cluster), do: {Jason.encode!(@public_account), 0}

  defp public_answer(["get", "clusterissuer", "ehos-acme-console", "-o", "jsonpath=" <> _], _),
    do: {@console_account, 0}

  defp public_answer(["get", "clusterissuer", "ehos-acme-addresses", "-o", "jsonpath=" <> _], _),
    do: {@addresses_account, 0}

  defp public_answer(["get", kind, "ehos-acme-" <> _ | _], _cluster)
       when kind in ["secret", "clusterissuer"],
       do: {"", 0}

  defp public_answer(_args, _cluster), do: nil

  defp public_zone do
    %{
      {@public_host, :a} => ["152.70.8.238"],
      {"*.#{@public_host}", :a} => ["152.70.8.238"],
      {"_acme-dns.#{@public_host}", :ns} => [@public_host],
      {"_acme-challenge.#{@public_host}", :cname} => [@challenge],
      {@public_host, :caa} => [
        {0, "issue", "letsencrypt.org; accounturi=#{@console_account}; validationmethods=dns-01"},
        {0, "issuewild", ";"}
      ],
      {"*.#{@public_host}", :caa} => [
        {0, "issue",
         "letsencrypt.org; accounturi=#{@addresses_account}; validationmethods=http-01"}
      ]
    }
  end

  # The company's zone client.example, with one name server, serving `zone`: a referral for
  # `_acme-dns.<host>`, and the wildcard's records for a name with none of its own; and acme-dns,
  # answering on the server's port 53.
  defp serve_zone(zone, opts \\ []) do
    port_53 = Keyword.get(opts, :port_53, :open)

    stub(DnsMock, :query, fn
      "_acme-dns.ehos.client.example", :soa, {152, 70, 8, 238} when port_53 == :closed ->
        {:error, "no answer (:timeout)"}

      "client.example", :soa, :recursive ->
        {:ok,
         %{
           rcode: :noerror,
           answers: [%{name: "client.example", type: :soa, data: "ns1.dns.example"}],
           authority: []
         }}

      _name, :soa, :recursive ->
        {:ok, %{rcode: :noerror, answers: [], authority: []}}

      "client.example", :ns, :recursive ->
        {:ok,
         %{
           rcode: :noerror,
           answers: [%{name: "client.example", type: :ns, data: "ns1.dns.example"}],
           authority: []
         }}

      "ns1.dns.example", :a, :recursive ->
        {:ok,
         %{
           rcode: :noerror,
           answers: [%{name: "ns1.dns.example", type: :a, data: "192.0.2.1"}],
           authority: []
         }}

      # acme-dns on the server, on port 53, authoritative for its zone alone.
      "_acme-dns.ehos.client.example", :soa, {152, 70, 8, 238} ->
        {:ok,
         %{
           rcode: :noerror,
           answers: [
             %{name: "_acme-dns.ehos.client.example", type: :soa, data: "ehos.client.example"}
           ],
           authority: []
         }}

      "_acme-dns." <> _ = name, :ns, {192, 0, 2, 1} ->
        referral =
          for data <- Map.get(zone, {name, :ns}, []), do: %{name: name, type: :ns, data: data}

        {:ok, %{rcode: :noerror, answers: [], authority: referral}}

      name, type, {192, 0, 2, 1} ->
        own? = Enum.any?(Map.keys(zone), &match?({^name, _}, &1))

        data =
          cond do
            Map.has_key?(zone, {name, type}) ->
              Map.fetch!(zone, {name, type})

            not own? and name == "edge.#{@public_host}" ->
              Map.get(zone, {"*.#{@public_host}", type}, [])

            true ->
              []
          end

        {:ok,
         %{
           rcode: :noerror,
           answers: for(d <- data, do: %{name: name, type: type, data: d}),
           authority: []
         }}
    end)
  end

  describe "traefik_serves/1" do
    # eh-os#846: a namespaced Traefik serves no console from ehos-system.
    test "refuses an EHOS release before 0.17.0, and judges nothing that names no release" do
      for version <- ["0.16.0", "0.17.0-dev"] do
        assert Install.traefik_serves(%{"version" => version}) ==
                 {:error,
                  "EHOS #{version} keeps its console's route where the Traefik this installer " <>
                    "installs no longer reads (eh-os D-117): its console would not answer. " <>
                    "Install 0.17.0 or later. Nothing was changed"}
      end

      for installed <- [
            %{"version" => "0.17.0"},
            %{"version" => "1.0.0"},
            nil,
            %{"version" => "not a version"}
          ],
          do: assert(Install.traefik_serves(installed) == :ok, inspect(installed))
    end
  end

  describe "prerequisites/1" do
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

    # eh-os#846: made before Traefik, as EHOS's chart makes it, and marked as that release's, which
    # Helm requires before it takes over a namespace it did not make.
    test "makes ehos-addresses as EHOS's chart does, marked as the ehos release's" do
      assert "addresses-namespace.yaml" |> Install.manifest() |> YamlElixir.read_from_file() ==
               {:ok,
                %{
                  "apiVersion" => "v1",
                  "kind" => "Namespace",
                  "metadata" => %{
                    "name" => "ehos-addresses",
                    "annotations" => %{
                      "helm.sh/resource-policy" => "keep",
                      "meta.helm.sh/release-name" => "ehos",
                      "meta.helm.sh/release-namespace" => "ehos-system"
                    },
                    "labels" => %{
                      "app.kubernetes.io/managed-by" => "Helm",
                      "pod-security.kubernetes.io/enforce" => "restricted",
                      "pod-security.kubernetes.io/audit" => "restricted",
                      "pod-security.kubernetes.io/warn" => "restricted"
                    }
                  }
                }}
    end

    test "leaves a prerequisite deployed at its pinned version with its values as it is", %{
      target: target
    } do
      calls = mock_prerequisites_deployed()

      assert Install.prerequisites(target) == :ok

      # Each is still waited for, as `helm upgrade --wait` did.
      assert calls.() ==
               local_calls(
                 prerequisite_steps(
                   false,
                   deployed_release_steps("cnpg") ++
                     deployed_release_steps("cert-manager") ++
                     deployed_release_steps("trust-manager") ++ deployed_release_steps("traefik")
                 )
               )
    end

    # eh-os D-143: EHOS's own pods run at 1000000, and depend on these. At the pinned charts,
    # cert-manager's global class is its controller's, cainjector's and webhook's; trust-manager's
    # and CloudNativePG's are their operator's (ehos-tools#500).
    test "runs every prerequisite's pods as system-cluster-critical", %{target: target} do
      calls = record_calls()

      assert Install.prerequisites(target) == :ok

      assert sets_matching(calls.(), "priorityClassName") == %{
               "cnpg" => ["priorityClassName=system-cluster-critical"],
               "cert-manager" => ["global.priorityClassName=system-cluster-critical"],
               "trust-manager" => ["priorityClassName=system-cluster-critical"],
               "traefik" => ["priorityClassName=system-cluster-critical"]
             }
    end

    # At the pinned charts, cert-manager's top-level `resources` is its controller's, and its
    # cainjector and webhook have their own; trust-manager's and CloudNativePG's are their
    # operator's. Requests alone: a memory limit would kill a controller that grows past it
    # (ehos-tools#576).
    test "requests CPU and memory for every prerequisite's long-running pods", %{target: target} do
      calls = record_calls()

      assert Install.prerequisites(target) == :ok

      assert sets_matching(calls.(), "resources.") == %{
               "cnpg" => ["resources.requests.cpu=20m", "resources.requests.memory=80Mi"],
               "cert-manager" => [
                 "cainjector.resources.requests.cpu=10m",
                 "cainjector.resources.requests.memory=48Mi",
                 "resources.requests.cpu=20m",
                 "resources.requests.memory=112Mi",
                 "webhook.resources.requests.cpu=10m",
                 "webhook.resources.requests.memory=48Mi"
               ],
               "trust-manager" => ["resources.requests.cpu=10m", "resources.requests.memory=48Mi"],
               "traefik" => ["resources.requests.cpu=100m", "resources.requests.memory=64Mi"]
             }
    end

    # ehos-tools#805: a tag can move, so each image that cert-manager's and trust-manager's pinned
    # charts render is set by the digest of its index. Traefik's names its digest in its tag
    # instead; CloudNativePG's operator still runs by tag.
    test "runs cert-manager's and trust-manager's images by the digests of their indexes", %{
      target: target
    } do
      calls = record_calls()

      assert Install.prerequisites(target) == :ok

      assert sets_matching(calls.(), "image.digest=") == %{
               "cnpg" => [],
               "cert-manager" => [
                 "acmesolver.image.digest=" <>
                   "sha256:699b40d622211ab7accad8a21b04c5fbaa1841ef7a12621e8de492dbe27b2503",
                 "cainjector.image.digest=" <>
                   "sha256:c85268c64f2e0e76684bf5fe8906caff34b82523561c6affe0fae3546bd87562",
                 "image.digest=" <>
                   "sha256:70f532fd9cfde0b09d55687200942399d89838bc2d5d5b45152eb799a15912b8",
                 "startupapicheck.image.digest=" <>
                   "sha256:46e75b6866359ffb5d82624f41e3ed1c70b2994982702ced547ce5edb418a8f5",
                 "webhook.image.digest=" <>
                   "sha256:a60e2dac46dbb8a7f3df95c54ce941012f54c2fe022f0ee55aaa1ab40ed957ae"
               ],
               "trust-manager" => [
                 "image.digest=" <>
                   "sha256:0521921c2a46d14d0417336b20bcde69215ef3164f2977cc939d53c6e5224a17"
               ],
               "traefik" => []
             }
    end

    test "upgrades a prerequisite installed with no class or requests, leaving Traefik as it is",
         %{target: target} do
      calls = mock_prerequisites_deployed_with(&before_class/1)

      assert Install.prerequisites(target) == :ok

      assert calls.() ==
               local_calls(
                 prerequisite_steps(
                   false,
                   release_steps("cnpg", true) ++
                     release_steps("cert-manager", true) ++
                     release_steps("trust-manager", true) ++ deployed_release_steps("traefik")
                 )
               )
    end

    # ehos_platform 0.13.0 runs cert-manager's images, all but its solver's, and trust-manager's by
    # tag (ehos-tools#805).
    test "upgrades cert-manager and trust-manager from 0.13.0, whose images ran by tag", %{
      target: target
    } do
      calls = mock_prerequisites_deployed_with(&before_digests/1)

      assert Install.prerequisites(target) == :ok

      assert calls.() ==
               local_calls(
                 prerequisite_steps(
                   false,
                   deployed_release_steps("cnpg") ++
                     release_steps("cert-manager", true) ++
                     release_steps("trust-manager", true) ++ deployed_release_steps("traefik")
                 )
               )
    end

    # ehos_platform 0.12.0 runs them as system-cluster-critical, with no requests
    # (ehos-tools#576).
    test "upgrades a prerequisite from 0.12.0, with a class and no requests", %{target: target} do
      calls = mock_prerequisites_deployed_with(&before_requests/1)

      assert Install.prerequisites(target) == :ok

      assert calls.() ==
               local_calls(
                 prerequisite_steps(
                   false,
                   release_steps("cnpg", true) ++
                     release_steps("cert-manager", true) ++
                     release_steps("trust-manager", true) ++ deployed_release_steps("traefik")
                 )
               )
    end

    test "installs one at another version, with other values, or not deployed", %{target: target} do
      calls =
        record_calls([
          {{"helm", ["list", "--namespace", "cnpg-system"]},
           {~s([{"chart": "cloudnative-pg-0.28.0", "status": "deployed"}]), 0}},
          {{"helm", ["list", "--namespace", "cert-manager", "--filter", "^cert-manager$"]},
           {~s([{"chart": "cert-manager-v1.21.2", "status": "deployed"}]), 0}},
          {{"helm", ["get", "values", "cert-manager"]}, {~s({"crds": {"enabled": true}}), 0}},
          {{"helm", ["list"]}, {~s([{"chart": "trust-manager-v0.25.0", "status": "failed"}]), 0}}
        ])

      assert Install.prerequisites(target) == :ok

      assert calls.() ==
               local_calls(
                 prerequisite_steps(
                   false,
                   release_steps("cnpg") ++
                     release_steps("cert-manager", true) ++
                     release_steps("trust-manager") ++ release_steps("traefik")
                 )
               )
    end

    # ehos-tools#429: a field changed by hand, `kubectl patch` on Traefik's args, failed the
    # upgrade, and the revision before it, reading every Secret, ran on. Each release is installed
    # by server-side apply, taking such a field back (`release_args/2`), and then Traefik's rights
    # are read as they are: only its own release's cluster-wide objects, and what the API server
    # lets its account do, asked as that account, with a deadline (`traefik_rights_steps/0`).
    test "takes each release's fields back by server-side apply, then reads Traefik's rights " <>
           "as its own account",
         %{target: target} do
      calls = record_calls()
      assert Install.prerequisites(target) == :ok
      assert calls.() == local_calls(prerequisite_steps())
    end

    test "takes kubectl's no with its reason, after a warning", %{target: target} do
      record_calls([
        {{:kubectl, ["auth", "can-i"]},
         {"Warning: resource 'secrets' is not namespace scoped\nno - RBAC: no rule\n", 1}}
      ])

      assert Install.prerequisites(target) == :ok
    end

    test "takes a warning kubectl prints for no cluster-wide object", %{target: target} do
      record_calls([
        {{:kubectl, ["get", "clusterrole,clusterrolebinding"]},
         {"Warning: client-side throttling, waited 1.2s\n", 0}}
      ])

      assert Install.prerequisites(target) == :ok
    end

    test "pulls CloudNativePG's chart by its digest, as the other two" do
      for release <- Install.prerequisite_releases() do
        assert release.chart =~ ~r/\Aoci:\/\/[a-z0-9.\/_-]+@sha256:[0-9a-f]{64}\z/, release.title
      end
    end

    # eh-os D-117: a cluster that is not a server, such as k3d's, is not switched but refused.
    test "refuses a cluster where k3s's Traefik is installed, installing nothing", %{
      target: target
    } do
      calls =
        record_calls([
          {{:kubectl, ["get", "crd", "helmcharts.helm.cattle.io"]}, {"crd/x", 0}},
          {{:kubectl, ["get", "helmchart"]}, {"traefik-crd", 0}}
        ])

      assert Install.prerequisites(target) ==
               {:error,
                "k3s's bundled Traefik is installed in this cluster (HelmChart traefik-crd in " <>
                  "kube-system), and EHOS installs its own in ehos-ingress (eh-os D-117). A " <>
                  "cluster is made without it by `disable: [traefik, gateway-api-crd]` in k3s's " <>
                  "configuration, or for k3d `--k3s-arg '--disable=traefik@server:*' " <>
                  "--k3s-arg '--disable=gateway-api-crd@server:*'`; k3s 1.37 installs its " <>
                  "Gateway API CRDs through a binding to cluster-admin, as it does its Traefik, " <>
                  "and EHOS uses no Gateway API (eh-os D-148). A server made before is switched " <>
                  "by installing EHOS on it with --switch-traefik (eh-os#823)"}

      assert calls.() == local_calls(bundled_traefik_steps(true))
    end

    test "installs no release when the ExternalName policy cannot be applied", %{target: target} do
      calls =
        record_calls([
          {external_names_policy_step(),
           {"error: the server could not find the requested resource", 1}}
        ])

      assert Install.prerequisites(target) ==
               {:error,
                "`kubectl` failed with exit status 1:\nerror: the server could not find the " <>
                  "requested resource"}

      assert calls.() == local_calls([helmcharts_crd_step(), external_names_policy_step()])
    end

    # eh-os#828: the policy sees only what is written after it.
    test "installs no release where an ExternalName Service made before is outside the two namespaces",
         %{target: target} do
      calls =
        record_calls([
          {{:kubectl, ["get", "services", "--all-namespaces"]},
           {"ehos-addresses/office\nehos-env-production/office\nehos-ingress/console\n", 0}}
        ])

      assert Install.prerequisites(target) ==
               {:error,
                "This cluster has an ExternalName Service outside ehos-addresses and " <>
                  "ehos-ingress (ehos-env-production/office), which EHOS's Traefik would follow " <>
                  "to whatever it names (eh-os#828). Remove it, or give it another type, and run " <>
                  "again. No prerequisite was installed or changed"}

      assert calls.() ==
               local_calls([
                 helmcharts_crd_step(),
                 external_names_policy_step(),
                 external_names_step()
               ])
    end

    test "refuses while Traefik's release still has cluster-wide rights, installed or not", %{
      target: target
    } do
      for installed? <- [false, true] do
        mock_traefik_cluster_rights(installed?)

        assert Install.prerequisites(target) ==
                 {:error,
                  "Traefik's release in ehos-ingress still has cluster-wide rights " <>
                    "(clusterrole.rbac.authorization.k8s.io/traefik-ehos-ingress, " <>
                    "clusterrolebinding.rbac.authorization.k8s.io/traefik-ehos-ingress), with " <>
                    "which it reads every Secret in the cluster; `helm history traefik -n " <>
                    "ehos-ingress` says why its last upgrade did not remove them"},
               inspect(installed?)
      end
    end

    test "refuses while the API server lets Traefik's account read the cluster's Secrets", %{
      target: target
    } do
      for {question, answer, expected} <- [
            {"list", {"yes", 0}, secrets_granted("list the Secrets of every namespace")},
            {"get", {"yes", 0}, secrets_granted("read the Secrets in ehos-system")},
            # kubectl exits 1 for its own errors as for a no: refused, never taken for one.
            {"list", {"error: You must be logged in to the server (Unauthorized)", 1},
             "`kubectl` failed with exit status 1:\nerror: You must be logged in to the server " <>
               "(Unauthorized)"},
            {"get",
             {~s|Error from server (Forbidden): users "x" is forbidden: User "x" cannot | <>
                ~s|impersonate resource "serviceaccounts"|, 1},
             "`kubectl` failed with exit status 1:\n" <>
               ~s|Error from server (Forbidden): users "x" is forbidden: User "x" cannot | <>
               ~s|impersonate resource "serviceaccounts"|},
            {"list", {"error: unknown flag: --request-timeout", 1},
             "`kubectl` failed with exit status 1:\nerror: unknown flag: --request-timeout"}
          ] do
        record_calls([{{:kubectl, ["auth", "can-i", question]}, answer}])

        assert Install.prerequisites(target) == {:error, expected}, expected
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

      assert Install.chart(target,
               repository: "ghcr.io/empoweredhouse/ehos",
               digest: @digest,
               ca_file: Path.join(tmp_dir, "ca.crt")
             ) == :ok

      # With no credential given, Helm's own login, if any, is what pulls it.
      assert calls.() ==
               on_cluster(
                 pulled_chart_steps(chart, chart_values(Path.join(tmp_dir, "ca.crt"), @host), []),
                 "ehos-trial",
                 "/k"
               )
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
    # ehos-tools#174, ehos-tools#300.
    test "is there, not there, or unknown when kubectl could not say" do
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
            # What kubectl answers before EHOS was ever installed (ehos-tools#300).
            {{~s|Error from server (NotFound): namespaces "ehos-system" not found|, 1},
             {:ok, false}},
            # kubectl's own answer is in what it says.
            {{~s|Error from server (NotFound): namespaces "other" not found|, 1},
             {:error,
              "kubectl could not say whether ehos-system holds the pull credential " <>
                ~s|ehos-pull-credential:\nError from server (NotFound): namespaces "other" | <>
                "not found"}},
            {{"Error from server (NotFound): the server could not find the requested resource",
              1},
             {:error,
              "kubectl could not say whether ehos-system holds the pull credential " <>
                "ehos-pull-credential:\nError from server (NotFound): the server could not " <>
                "find the requested resource"}},
            {{"Unable to connect to the server: i/o timeout", 1},
             {:error,
              "kubectl could not say whether ehos-system holds the pull credential " <>
                "ehos-pull-credential:\nUnable to connect to the server: i/o timeout"}}
          ] do
        mock_pull_credential(answer)

        assert Install.pull_credential(target) == expected
      end
    end
  end

  # ehos-tools#680: CloudNativePG gives a cluster's priority class (eh-os D-143) only to a new pod.
  describe "restart_outdated_databases/1" do
    setup do
      target = %Install{
        context: "ehos-trial",
        host: @host,
        kubeconfig: "/k",
        source: @source,
        runner: CommandRunnerMock,
        clock: ClockMock,
        progress: &send(self(), {:progress, &1})
      }

      stub_now()
      %{target: target}
    end

    test "restarts each cluster whose pods run without its class, one at a time, until each is healthy on new pods",
         %{target: target} do
      governance = "ehos-governance-db"
      healthy = cnpg_json(cnpg_cluster(governance, "ehos-platform"))

      calls =
        mock_databases(
          %{
            "ehos-system" =>
              {[cnpg_cluster(governance, "ehos-platform")], [instance_pod(governance, nil)]},
            "ehos-data" =>
              {[cnpg_cluster("shared", "ehos-platform"), cnpg_cluster("trial", "ehos-platform")],
               [instance_pod("shared", nil), instance_pod("trial", "ehos-platform")]}
          },
          %{
            governance => [
              # The cluster cannot be asked, so it is asked again.
              {{"Unable to connect to the server: i/o timeout", 1}, nil},
              # Right after the annotation: healthy, on the old pod.
              {healthy, kubectl_list([instance_pod(governance, nil)])},
              {cnpg_json(
                 cnpg_cluster(
                   governance,
                   "ehos-platform",
                   "Waiting for the instances to become active"
                 )
               ), kubectl_list([instance_pod(governance, "ehos-platform", "False")])},
              {healthy, kubectl_list([instance_pod(governance, "ehos-platform")])}
            ],
            "shared" => [
              {cnpg_json(cnpg_cluster("shared", "ehos-platform")),
               kubectl_list([instance_pod("shared", "ehos-platform")])}
            ]
          }
        )

      expect(ClockMock, :sleep, 3, fn 5_000 -> :ok end)

      assert Install.restart_outdated_databases(target) == :ok

      assert calls.() ==
               on_cluster(
                 database_list_steps(["ehos-system", "ehos-data"]) ++
                   database_restart_steps("ehos-system", governance) ++
                   [hd(database_poll_steps("ehos-system", governance))] ++
                   List.flatten(List.duplicate(database_poll_steps("ehos-system", governance), 3)) ++
                   database_restart_steps("ehos-data", "shared") ++
                   database_poll_steps("ehos-data", "shared"),
                 "ehos-trial",
                 "/k"
               )

      assert for({:progress, line} <- drain(), do: line) == [
               "The PostgreSQL pods of ehos-system/ehos-governance-db, ehos-data/shared do not " <>
                 "run with the priority class that their cluster gives. Each cluster is " <>
                 "restarted, one at a time. A cluster of one instance is down until its new pod " <>
                 "is ready, usually 1 to 3 minutes. The command checks a cluster at most 120 " <>
                 "times, 5 s apart. The console stops while a cluster in ehos-system restarts. The " <>
                 "applications of an instance in ehos-data stop while that instance restarts",
               "Restarting PostgreSQL ehos-system/ehos-governance-db, so that its pods run with " <>
                 "the priority class ehos-platform, and waiting until it is healthy",
               "PostgreSQL ehos-system/ehos-governance-db is healthy again",
               "Restarting PostgreSQL ehos-data/shared, so that its pods run with the priority " <>
                 "class ehos-platform, and waiting until it is healthy",
               "PostgreSQL ehos-data/shared is healthy again"
             ]
    end

    # Compared with the spec, never a version: a later upgrade restarts nothing.
    test "leaves a cluster whose pods run with its class, one that gives none, and one with no pod yet",
         %{target: target} do
      calls =
        mock_databases(%{
          "ehos-system" =>
            {[cnpg_cluster("ehos-governance-db", "ehos-platform")],
             [instance_pod("ehos-governance-db", "ehos-platform")]},
          "ehos-data" => {
            [cnpg_cluster("shared", nil), cnpg_cluster("trial", "ehos-platform")],
            # A cluster's `globalDefault` class, given to a pod that names none.
            [instance_pod("shared", "cluster-default")]
          }
        })

      assert Install.restart_outdated_databases(target) == :ok

      assert calls.() ==
               on_cluster(database_list_steps(["ehos-system", "ehos-data"]), "ehos-trial", "/k")

      assert drain() == []
    end

    test "leaves a cluster that is no longer healthy when its turn to restart comes", %{
      target: target
    } do
      calls =
        mock_databases(
          %{
            "ehos-data" =>
              {[cnpg_cluster("shared", "ehos-platform"), cnpg_cluster("trial", "ehos-platform")],
               [instance_pod("shared", nil), instance_pod("trial", nil)]}
          },
          %{
            "shared" => [],
            "trial" => [
              {cnpg_json(cnpg_cluster("trial", "ehos-platform")),
               kubectl_list([instance_pod("trial", "ehos-platform")])}
            ]
          },
          %{"shared" => cnpg_cluster("shared", "ehos-platform", "Failing over")}
        )

      assert Install.restart_outdated_databases(target) == :ok

      assert calls.() ==
               on_cluster(
                 database_list_steps(["ehos-data"]) ++
                   [hd(database_poll_steps("ehos-data", "shared"))] ++
                   database_restart_steps("ehos-data", "trial") ++
                   database_poll_steps("ehos-data", "trial"),
                 "ehos-trial",
                 "/k"
               )

      assert {:progress,
              ~s|PostgreSQL ehos-data/shared is not restarted, because it is not healthy | <>
                ~s|(phase "Failing over"). Its pods run without the priority class | <>
                "ehos-platform until it is healthy and the command runs again"} in drain()
    end

    # CloudNativePG rolls a cluster of several instances one pod at a time.
    test "waits until every pod of a cluster of several instances is new", %{target: target} do
      healthy = cnpg_json(cnpg_cluster("shared", "ehos-platform", "Cluster in healthy state", 2))
      new = &instance_pod("shared", "ehos-platform", "True", &1)
      old = &instance_pod("shared", nil, "True", &1)

      calls =
        mock_databases(
          %{
            "ehos-data" =>
              {[cnpg_cluster("shared", "ehos-platform", "Cluster in healthy state", 2)],
               [old.(1), old.(2)]}
          },
          %{
            "shared" => [
              {healthy, kubectl_list([new.(1), old.(2)])},
              {healthy, kubectl_list([new.(1)])},
              {healthy, kubectl_list([new.(1), new.(2)])}
            ]
          }
        )

      expect(ClockMock, :sleep, 2, fn 5_000 -> :ok end)

      assert Install.restart_outdated_databases(target) == :ok

      assert calls.() ==
               on_cluster(
                 database_list_steps(["ehos-data"]) ++
                   database_restart_steps("ehos-data", "shared") ++
                   List.flatten(List.duplicate(database_poll_steps("ehos-data", "shared"), 3)),
                 "ehos-trial",
                 "/k"
               )
    end

    # One that cannot come back from a restart would only be taken down again on every run.
    test "leaves a cluster that is not healthy before its restart, and says so", %{target: target} do
      failing = cnpg_cluster("shared", "ehos-platform", "Setting up primary")

      calls =
        mock_databases(
          %{
            "ehos-data" =>
              {[failing, cnpg_cluster("trial", "ehos-platform")],
               [instance_pod("shared", nil, "False"), instance_pod("trial", nil)]}
          },
          %{
            "trial" => [
              {cnpg_json(cnpg_cluster("trial", "ehos-platform")),
               kubectl_list([instance_pod("trial", "ehos-platform")])}
            ]
          }
        )

      assert Install.restart_outdated_databases(target) == :ok

      assert calls.() ==
               on_cluster(
                 database_list_steps(["ehos-data"]) ++
                   database_restart_steps("ehos-data", "trial") ++
                   database_poll_steps("ehos-data", "trial"),
                 "ehos-trial",
                 "/k"
               )

      assert for({:progress, line} <- drain(), do: line) == [
               ~s|PostgreSQL ehos-data/shared is not restarted, because it is not healthy | <>
                 ~s|(phase "Setting up primary"). Its pods run without the priority class | <>
                 "ehos-platform until it is healthy and the command runs again",
               "The PostgreSQL pods of ehos-data/trial do not run with the priority class that " <>
                 "their cluster gives. Each cluster is restarted, one at a time. A cluster of one " <>
                 "instance is down until its new pod is ready, usually 1 to 3 minutes. The " <>
                 "command checks a cluster at most 120 times, 5 s apart. The console stops while " <>
                 "a cluster in ehos-system restarts. The applications of an instance in ehos-data " <>
                 "stop while that instance restarts",
               "Restarting PostgreSQL ehos-data/trial, so that its pods run with the priority " <>
                 "class ehos-platform, and waiting until it is healthy",
               "PostgreSQL ehos-data/trial is healthy again"
             ]
    end

    test "says what it saw last when a cluster is not healthy on new pods after 120 checks, and restarts no other",
         %{target: target} do
      old =
        {cnpg_json(cnpg_cluster("shared", "ehos-platform")),
         kubectl_list([instance_pod("shared", nil)])}

      calls =
        mock_databases(
          %{
            "ehos-data" =>
              {[cnpg_cluster("shared", "ehos-platform"), cnpg_cluster("trial", "ehos-platform")],
               [instance_pod("shared", nil), instance_pod("trial", nil)]}
          },
          %{"shared" => [old]}
        )

      expect(ClockMock, :sleep, 120, fn 5_000 -> :ok end)

      assert Install.restart_outdated_databases(target) ==
               {:error,
                "PostgreSQL ehos-data/shared was not healthy on new pods after 120 checks, 5 s " <>
                  ~s|apart, since its restart (last: phase "Cluster in healthy state", 1 of 1 | <>
                  "pods ready, 0 of 1 with the priority class ehos-platform). CloudNativePG may " <>
                  "still be restarting it: see `kubectl describe clusters.postgresql.cnpg.io -n " <>
                  "ehos-data shared`. Once it is healthy, run the command again to restart any " <>
                  "cluster whose pods still run without its priority class"}

      assert calls.() ==
               on_cluster(
                 database_list_steps(["ehos-data"]) ++
                   database_restart_steps("ehos-data", "shared") ++
                   List.flatten(List.duplicate(database_poll_steps("ehos-data", "shared"), 120)),
                 "ehos-trial",
                 "/k"
               )
    end

    test "reads kubectl's JSON among the warnings it prints before and after it", %{
      target: target
    } do
      {listing, 0} = kubectl_list([cnpg_cluster("shared", "ehos-platform")])
      {pods, 0} = kubectl_list([instance_pod("shared", "ehos-platform")])

      warned =
        &{"Warning: v1 ComponentStatus is deprecated\n" <> &1 <> "\nW1031 a later warning\n", 0}

      calls =
        record_calls([
          {{:kubectl, ["get", "clusters.postgresql.cnpg.io"]}, warned.(listing)},
          {{:kubectl, ["get", "pods"]},
           warned.(
             Jason.encode_to_iodata!(Jason.decode!(pods), pretty: true)
             |> IO.iodata_to_binary()
           )}
        ])

      assert Install.restart_outdated_databases(target) == :ok
      assert drain() == []

      # The cluster in ehos-system matched its pods, so ehos-data's listing is asked for too.
      assert calls.() ==
               on_cluster(database_list_steps(["ehos-system", "ehos-data"]), "ehos-trial", "/k")
    end

    test "restarts nothing when kubectl cannot list the clusters or answers with no JSON", %{
      target: target
    } do
      for {answer, said} <- [
            {{"Unable to connect to the server: i/o timeout", 1},
             "`kubectl` failed with exit status 1:\nUnable to connect to the server: i/o timeout"},
            {{"No resources found\n", 0},
             "`kubectl get clusters.postgresql.cnpg.io -n ehos-system --request-timeout=10s -o json` " <>
               "did not answer with JSON:\nNo resources found\n"}
          ] do
        calls = record_calls([{{:kubectl, ["get", "clusters.postgresql.cnpg.io"]}, answer}])

        assert Install.restart_outdated_databases(target) ==
                 {:error,
                  "The PostgreSQL clusters could not be compared with their pods, so none was " <>
                    "restarted: #{said}\nRun the command again to restart any healthy cluster " <>
                    "whose pods run without its priority class"}

        assert calls.() ==
                 on_cluster(
                   [
                     {:kubectl,
                      [
                        "get",
                        "clusters.postgresql.cnpg.io",
                        "-n",
                        "ehos-system",
                        "--request-timeout=10s",
                        "-o",
                        "json"
                      ]}
                   ],
                   "ehos-trial",
                   "/k"
                 )
      end
    end

    test "restarts no cluster after one kubectl could not restart", %{target: target} do
      listed = %{
        "ehos-data" =>
          {[cnpg_cluster("shared", "ehos-platform"), cnpg_cluster("trial", "ehos-platform")],
           [instance_pod("shared", nil), instance_pod("trial", nil)]}
      }

      before = [{cnpg_json(cnpg_cluster("shared", "ehos-platform")), nil}]
      {:ok, agent} = Agent.start_link(fn -> %{checks: %{"shared" => before}, pods: %{}} end)

      calls =
        record_calls(fn
          "kubectl", args ->
            case step(args) do
              ["annotate" | _] -> {"Error from server (Forbidden)", 1}
              step -> database_answer(step, listed, agent)
            end

          _program, _args ->
            nil
        end)

      assert Install.restart_outdated_databases(target) ==
               {:error,
                "kubectl did not confirm that PostgreSQL ehos-data/shared was asked to restart: " <>
                  "`kubectl` failed with exit status 1:\nError from server (Forbidden)\nRun the " <>
                  "command again to restart it, once it is healthy, and the clusters after it"}

      assert calls.() ==
               on_cluster(
                 database_list_steps(["ehos-data"]) ++
                   database_restart_steps("ehos-data", "shared"),
                 "ehos-trial",
                 "/k"
               )
    end
  end

  describe "tunnel_address/1" do
    test "reads the installation under the operator's home when :home is from ~/",
         %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, ".ehos/trial")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "tunnel.json"), ~s({"address":"152.70.8.238","port":16443}))
      stub(EnvMock, :get, fn "HOME" -> tmp_dir end)

      assert Install.tunnel_address(env: EnvMock) == "152.70.8.238"
      assert Install.tunnel_address(home: "~/elsewhere", env: EnvMock) == nil
    end
  end

  describe "installed/1" do
    setup %{tmp_dir: tmp_dir} do
      home = Path.join(tmp_dir, "ehos")
      File.mkdir_p!(Path.join(home, "acme"))
      File.write!(Path.join([home, "acme", "kubeconfig"]), "{}")
      %{opts: [runner: CommandRunnerMock, home: home, name: "acme"], home: home}
    end

    # eh-os D-128, ehos-tools#350: what the server runs with, given or decided by the chart, from
    # the objects the deployed revision applied; nothing when it does not say or cannot be read.
    test "reads whether the deployed revision's server runs with four eyes", %{
      opts: opts,
      home: home
    } do
      for {answer, expected} <- [
            {manifest(true), true},
            {manifest(false), false},
            {manifest(nil), nil},
            # Not as the chart renders it: not read.
            {{"- name: EHOS_PROMOTION_FOUR_EYES\n  value: true\n", 0}, nil},
            {{"Error: something\n", 1}, nil}
          ] do
        mock_helm([
          history([{1, "deployed"}]),
          {Jason.encode!(%{"installed" => @installed}), 0},
          answer
        ])

        assert Install.installed(opts) ==
                 {:ok, %{installed(@installed) | four_eyes_runs: expected}}

        assert for({:helm, args} <- drain(), do: args) == helm_reads(home, 1)
      end
    end

    test "reads what server/1 recorded in the last deployed revision, through the installation's kubeconfig and context",
         %{opts: opts, home: home} do
      mock_helm([
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
               {:ok, %{installed(@installed) | digest: @digest, host: @host}}

      assert for({:helm, args} <- drain(), do: args) == helm_reads(home, 2)
    end

    test "reads the deployed revision when a later one failed or is pending, and says which", %{
      opts: opts,
      home: home
    } do
      for status <- ["failed", "pending-upgrade"] do
        mock_helm([
          history([{3, "superseded"}, {4, "deployed"}, {5, status}]),
          {Jason.encode!(%{"installed" => @installed}), 0},
          manifest(nil)
        ])

        assert Install.installed(opts) ==
                 {:ok,
                  %{
                    installed(@installed)
                    | last: %{revision: 5, status: status, description: "#{status} at 5"}
                  }}

        assert for({:helm, args} <- drain(), do: args) == helm_reads(home, 4)
      end
    end

    test "is none where EHOS is not installed, or where no revision was ever deployed", %{
      opts: opts
    } do
      mock_helm([{"Error: release: not found\n", 1}])
      assert Install.installed(opts) == {:ok, installed(:none)}

      mock_helm([history([{1, "failed"}])])

      assert Install.installed(opts) ==
               {:ok,
                %{
                  installed(:none)
                  | last: %{revision: 1, status: "failed", description: "failed at 1"}
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
        mock_helm([history([{1, "deployed"}]), {output, 0}, manifest(nil)])

        assert Install.installed(opts) ==
                 {:ok, %{installed(:unknown) | digest: digest, host: host}}
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
        mock_helm([
          history([{1, "deployed"}]),
          {Jason.encode!(%{"installed" => @installed, "governance" => %{"signIn" => sign_in}}),
           0},
          manifest(nil)
        ])

        assert Install.installed(opts) == {:ok, %{installed(@installed) | sign_in: expected}}
      end
    end

    # eh-os D-155: a list of names alone, which the next install keeps.
    test "reads the domains the deployed revision allows", %{opts: opts} do
      for {allowed, expected} <- [
            {["client.example", "client.co.uk"], ["client.example", "client.co.uk"]},
            {[], nil},
            {["client.example", 1], nil},
            {"client.example", nil}
          ] do
        mock_helm([
          history([{1, "deployed"}]),
          {Jason.encode!(%{
             "installed" => @installed,
             "environments" => %{"domains" => %{"allowed" => allowed}}
           }), 0},
          manifest(nil)
        ])

        assert Install.installed(opts) ==
                 {:ok, %{installed(@installed) | allowed_domains: expected}}
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
        mock_helm([
          history([{1, "deployed"}]),
          {Jason.encode!(%{
             "installed" => @installed,
             "governance" => %{"promotion" => promotion}
           }), 0},
          manifest(nil)
        ])

        assert Install.installed(opts) == {:ok, %{installed(@installed) | four_eyes: expected}}
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
        mock_helm([
          history([{1, "deployed"}]),
          {Jason.encode!(%{"installed" => @installed, "governance" => %{"mail" => mail}}), 0},
          manifest(nil)
        ])

        assert Install.installed(opts) == {:ok, %{installed(@installed) | mail: expected}}
      end
    end

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

    test "says why it could not read the release", %{opts: opts, home: home} do
      mock_helm([{"Error: Kubernetes cluster unreachable\n", 1}])

      assert Install.installed(opts) ==
               {:error,
                "`helm` failed with exit status 1:\nError: Kubernetes cluster unreachable\n\n" <>
                  "Is the tunnel open? `mix ehos.server tunnel` opens it."}

      mock_helm([{"not json", 0}])

      assert Install.installed(opts) ==
               {:error,
                "`helm history` gave something other than the release's revisions:\nnot json"}

      mock_helm([{~s([{"revision":1}]), 0}])

      assert Install.installed(opts) ==
               {:error,
                ~s|`helm history` gave a revision without its number or status:\n[{"revision":1}]|}

      mock_helm([history([{1, "deployed"}]), {"[1]", 0}])

      assert Install.installed(opts) ==
               {:error, "`helm get values` gave something other than the release's values:\n[1]"}

      mock_helm([history([{1, "deployed"}]), {"Error: timeout\n", 1}])

      assert Install.installed(opts) ==
               {:error,
                "`helm` failed with exit status 1:\nError: timeout\n\nIs the tunnel open? " <>
                  "`mix ehos.server tunnel` opens it."}

      kubeconfig = Path.join([home, "other", "kubeconfig"])

      assert Install.installed(
               Keyword.merge(opts, name: "other", server_command: "ehosctl server")
             ) ==
               {:error,
                "#{kubeconfig} is missing. Open the tunnel first: `ehosctl server tunnel`"}

      assert Install.installed(
               Keyword.merge(opts,
                 name: "other",
                 server_command: "ehosctl server",
                 name_option: "--installation",
                 name_in_commands: true
               )
             ) ==
               {:error,
                "#{kubeconfig} is missing. Open the tunnel first: " <>
                  "`ehosctl server tunnel --installation other`"}
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

    test "runs EHOS's release command in the governance container, through the installation's " <>
           "kubeconfig and context, and returns the link it printed",
         %{opts: opts, home: home} do
      mock_kubectl_exec(
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

    test "returns no administrator's line once someone is administrator, a joined person's " <>
           "included",
         %{opts: opts} do
      mock_kubectl_exec(
        {"Invited ada@example.com. This link signs them in once, within 15 minutes:\r\n" <>
           @link <> "\r\n", 0}
      )

      assert Install.invite(opts) ==
               {:ok,
                %{
                  invited:
                    "Invited ada@example.com. This link signs them in once, within 15 minutes:",
                  link: @link,
                  administrator: nil,
                  interrupted: nil
                }}
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
        mock_kubectl_exec(
          {"Invited x. This link signs them in once, within 15 minutes:\n#{@link}", 0}
        )

        assert Install.invite(Keyword.put(opts, :email, email)) ==
                 {:ok,
                  %{
                    invited: "Invited x. This link signs them in once, within 15 minutes:",
                    link: @link,
                    administrator: nil,
                    interrupted: nil
                  }}

        assert_received {:kubectl, args, _timeout}
        expression = List.last(args)

        assert expression |> Code.string_to_quoted!() |> without_meta() ==
                 {{:., [], [{:__aliases__, [], [:Ehos, :Release]}, :invite]}, [], [email]}

        # Evaluated against a stand-in for EHOS's module (test/support/ehos_release.ex): a
        # `throw/1` that got out of the string would end this test here.
        assert Code.eval_string(expression) == {:ok, []}
        assert_received {:invited, ^email}
      end
    end

    test "finds the link past a log line, and when kubectl failed after EHOS printed it", %{
      opts: opts
    } do
      mock_kubectl_exec(
        {"Invited ada@example.com. This link signs them in once, within 15 minutes:\n" <>
           "12:00:01.123 [info] a log line from stderr\n" <> @link <> "\n", 0}
      )

      assert Install.invite(opts) ==
               {:ok,
                %{
                  invited:
                    "Invited ada@example.com. This link signs them in once, within 15 minutes:",
                  link: @link,
                  administrator: nil,
                  interrupted: nil
                }}

      mock_kubectl_exec(
        {"Invited ada@example.com. This link signs them in once, within 15 minutes:\n" <>
           @link <> "\nerror: lost connection to pod\n", 1}
      )

      assert Install.invite(opts) ==
               {:ok,
                %{
                  invited:
                    "Invited ada@example.com. This link signs them in once, within 15 minutes:",
                  link: @link,
                  administrator: nil,
                  interrupted:
                    "kubectl failed with exit status 1 after EHOS printed the link, so what EHOS " <>
                      "said after it may be missing: if nobody was the platform's " <>
                      "administrator, this person is now."
                }}
    end

    # ehos-tools#543, as for server/1.
    test "refuses a missing :email by its name", %{opts: opts} do
      assert_raise KeyError, "key :email not found", fn ->
        Install.invite(Keyword.delete(opts, :email))
      end
    end

    test "refuses before kubectl runs an address EHOS would refuse, or one that acts on the " <>
           "terminal",
         %{opts: opts} do
      for {email, refusal} <- [
            {"", :form},
            {"ada", :form},
            {"@example.com", :form},
            {"ada@", :form},
            {"ada@b@example.com", :form},
            {"ada @example.com", :printable},
            {"ada@example.com,alan@example.com", :form},
            {"ada@example.com;alan@example.com", :form},
            {"ada@example.com\nalan@example.com", :printable},
            {"ada" <> <<0xA0::utf8>> <> "@example.com", :printable},
            {"ada@example.com" <> <<0xA0::utf8>>, :printable},
            {"ada@example" <> <<0x3000::utf8>> <> ".com", :printable},
            {"ada\0@example.com", :printable},
            {"ada" <> <<0xAD::utf8>> <> "@example.com", :printable},
            {"ada\e[2J@example.com", :printable},
            {"ada" <> <<0x202E::utf8>> <> "@example.com", :printable},
            {"ada" <> <<0xFF>> <> "@example.com", :printable},
            {String.duplicate("a", 150) <> "@example.com", :long}
          ] do
        # No kubectl answer is expected: Mox fails the test if it is run.
        assert Install.invite(Keyword.put(opts, :email, email)) ==
                 {:error, not_taken(email, refusal)},
               email
      end
    end

    test "takes no link whose token was cut short or that carries more", %{opts: opts} do
      for link <- [
            String.slice(@link, 0..-5//1),
            @link <> "#fragment",
            @link <> "?a=b",
            String.replace(@link, "https", "ftp")
          ] do
        mock_kubectl_exec(
          {"Invited ada@example.com. This link signs them in once:\n#{link}\n" <>
             "error: lost connection to pod\n", 1}
        )

        assert Install.invite(opts) ==
                 {:error,
                  "`kubectl` failed with exit status 1:\nInvited ada@example.com. This link " <>
                    "signs them in once:\n" <>
                    hidden(link) <>
                    "\nerror: lost connection to pod\n\n" <>
                    "Is the tunnel open? `ehosctl server tunnel` opens it."}
      end
    end

    test "hides a sign-in link in what a failed kubectl printed", %{opts: opts} do
      mock_kubectl_exec(
        {"Invited ada@example.com. This link signs them in once:\n" <>
           "https://ehos.example.org/people/log-in/SFMyNTY.secret\u001B[2J\n" <>
           "error: lost connection to pod\n", 1}
      )

      assert Install.invite(opts) ==
               {:error,
                "`kubectl` failed with exit status 1:\nInvited ada@example.com. This link signs " <>
                  "them in once:\nhttps://ehos.example.org/people/log-in/[hidden]\nerror: lost " <>
                  "connection to pod\n\nIs the tunnel open? `ehosctl server tunnel` opens it."}
    end

    test "says why EHOS did not invite, from the first line of what it raised", %{opts: opts} do
      mock_kubectl_exec(
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
      mock_kubectl_exec({"The connection to the server 127.0.0.1:16443 was refused\n", 1})

      assert Install.invite(opts) ==
               {:error,
                "`kubectl` failed with exit status 1:\nThe connection to the server " <>
                  "127.0.0.1:16443 was refused\n\nIs the tunnel open? `ehosctl server tunnel` " <>
                  "opens it."}

      mock_kubectl_exec({:error, :timeout})

      assert Install.invite(opts) ==
               {:error,
                "kubectl did not finish within 2 minutes, and no link reached ehosctl. EHOS may " <>
                  "still have invited them, and made them administrator if nobody was: run it " <>
                  "again for a link.\nIs the tunnel open? `ehosctl server tunnel` opens it."}

      mock_kubectl_exec({:error, :not_found})

      assert Install.invite(opts) ==
               {:error,
                "`kubectl` is not installed, or not at the version EHOS pins: `ehosctl doctor` " <>
                  "says what is missing (`mix ehos.doctor` in eh-os)"}
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
        mock_kubectl_exec({output, 0})

        assert Install.invite(opts) ==
                 {:error,
                  "EHOS ran the invitation of ada@example.com but printed no sign-in link in " <>
                    "the form this version knows. What it printed is below; a link in it is a " <>
                    "password, for that person alone:\n" <> output}
      end
    end

    test "says to open the tunnel when there is no kubeconfig, and refuses a name that is not one",
         %{opts: opts, home: home} do
      assert Install.invite(Keyword.put(opts, :name, "other")) ==
               {:error,
                "#{Path.join([home, "other", "kubeconfig"])} is missing. Open the tunnel first: " <>
                  "`ehosctl server tunnel`"}

      assert Install.invite(Keyword.put(opts, :name, "Not A Name")) ==
               {:error,
                "The installation's name is 2 to 16 lowercase letters, digits and hyphens"}
    end

    test "names the installation in the tunnel it says to open, when asked to", %{
      opts: opts,
      home: home
    } do
      opts =
        Keyword.merge(opts, name: "other", name_option: "--installation", name_in_commands: true)

      assert Install.invite(opts) ==
               {:error,
                "#{Path.join([home, "other", "kubeconfig"])} is missing. Open the tunnel first: " <>
                  "`ehosctl server tunnel --installation other`"}
    end
  end

  # Stubs every program with what a fresh cluster answers, letting `override` answer first (nil to
  # fall through), and returns a function listing the calls made, in order, each directory
  # TmpDir made pinned as `tmp/2` names it. `override` is a function of the program and its
  # arguments, or a list of `{{program, step}, answer}`: the answer to each call of `program`, a
  # step's `:kubectl` or `:helm` too, whose arguments, after the ones that point kubectl at the
  # cluster and with TmpDir's directories pinned, begin with `step`.
  defp record_calls(override \\ fn _program, _args -> nil end)

  defp record_calls(answers) when is_list(answers),
    do: record_calls(&answered(answers, &1, &2))

  defp record_calls(override) when is_function(override, 2) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    stub(CommandRunnerMock, :run, fn program, args ->
      Agent.update(agent, &[{program, args} | &1])

      case override.(program, args) do
        nil -> answer(program, args)
        result -> result
      end
    end)

    fn -> agent |> Agent.get(& &1) |> Enum.reverse() |> Enum.map(&pin_random/1) end
  end

  defp answered(answers, program, args) do
    {_program, pinned} = pin_random({program, args})

    Enum.find_value(answers, fn {{answering, step}, answer} ->
      if to_string(answering) == program and List.starts_with?(step(pinned), step), do: answer
    end)
  end

  defp answer("kubectl", args) do
    case step(args) do
      ["get", "secret", "ehos-local-ca" | _] ->
        {"Warning: a line first\n" <> Base.encode64(@ca_pem), 0}

      # As the API server answers for a Traefik confined to its namespaces.
      ["auth", "can-i" | _] ->
        {"no", 1}

      # No CloudNativePG cluster, and no pod of one.
      ["get", resource, "-n" | _] when resource in ["clusters.postgresql.cnpg.io", "pods"] ->
        {~s({"apiVersion":"v1","items":[],"kind":"List"}), 0}

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

  # A directory TmpDir makes ends in random characters, the one part of a call a test cannot
  # know: pinned to `<random>`, the rest of the call is compared whole.
  defp pin_random({program, args}) do
    random =
      Regex.compile!(
        "(" <>
          Regex.escape(Path.join(System.tmp_dir!(), "ehos-")) <>
          "[a-z-]+)-" <>
          "[A-Za-z0-9_-]{16}(?=/|\\z)"
      )

    {program, Enum.map(args, &Regex.replace(random, &1, "\\1-<random>"))}
  end

  # The directory TmpDir makes with `prefix`, or a file in it, as `record_calls/1` pins it.
  defp tmp(prefix), do: Path.join(System.tmp_dir!(), prefix <> "-<random>")
  defp tmp(prefix, file), do: Path.join(tmp(prefix), file)

  # The calls `steps` are against a cluster: kubectl named it first, Helm last. A step that is
  # already a call, `{"helm", args}`, is one that names no cluster.
  defp on_cluster(steps, context, kubeconfig \\ nil) do
    kubeconfig_args = if kubeconfig, do: ["--kubeconfig", kubeconfig], else: []

    Enum.map(steps, fn
      {:kubectl, args} -> {"kubectl", kubeconfig_args ++ ["--context", context | args]}
      {:helm, args} -> {"helm", args ++ ["--kube-context", context | kubeconfig_args]}
      {program, args} when is_binary(program) -> {program, args}
    end)
  end

  # The calls `steps` are against the local cluster prerequisites/1 is given.
  defp local_calls(steps), do: on_cluster(steps, "k3d-ehos")

  # The calls `steps` are against the installation server/1 installs, through its kubeconfig.
  defp server_calls(dir, steps), do: on_cluster(steps, "ehos-trial", Path.join(dir, "kubeconfig"))

  # The shim's fields stay on a Certificate an Ingress owns; one the chart made has Helm's alone.
  defp mock_console_certificate(made_by, chart, fields \\ nil) do
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

  # eh-os D-117: EHOS installs its own Traefik; one k3s bundles would contend with it for the
  # ports 80 and 443.
  defp mock_bundled_traefik(crd, helmchart) do
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
  defp mock_server_with_bundled_traefik(
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
       ),
       do: bundled_until(gone_after, bundled)

  # The CRDs may outlast the HelmCharts, by `crds_after` asks.
  defp switching_kubectl(
         ["get", "crd", "--request-timeout=10s", "-o", "jsonpath=" <> _],
         gone_after,
         crds_after,
         _bundled
       ) do
    if Process.get(:asked_after, 0) > gone_after + crds_after,
      do: {"", 0},
      else: {"ingressroutes.traefik.io middlewares.traefik.io ", 0}
  end

  defp switching_kubectl(_other, _gone, _crds, _bundled), do: nil

  defp bundled_until(gone_after, bundled) do
    if Process.get(:switched) do
      asked = Process.get(:asked_after, 0) + 1
      Process.put(:asked_after, asked)

      cond do
        asked == 1 -> {"The connection to the server 127.0.0.1:16443 was refused", 1}
        asked > gone_after -> {"", 0}
        true -> {bundled, 0}
      end
    else
      {"Warning: first\n" <> bundled, 0}
    end
  end

  # What prerequisites/1 says when Traefik's account may `what`.
  defp secrets_granted(what),
    do:
      "Traefik's service account system:serviceaccount:ehos-ingress:traefik may #{what}: some " <>
        "binding outside its release gives it Secrets, the keys that sign EHOS's credentials " <>
        "among them (eh-os D-117). Remove that binding"

  # Every prerequisite deployed at its pinned version with its values.
  defp mock_prerequisites_deployed, do: record_calls(&deployed/2)

  # Every prerequisite deployed at its pinned version, with the values `before` gives for it as
  # `helm get values` reports them: Helm prints `null` for none at all.
  defp mock_prerequisites_deployed_with(before) do
    record_calls(fn
      "helm", ["get", "values", release | _] -> helm_values(before.(prerequisite(release)))
      program, args -> deployed(program, args)
    end)
  end

  defp helm_values(values) when values == %{}, do: {"null\n", 0}
  defp helm_values(values), do: {Jason.encode!(values), 0}

  # A prerequisite's values as an installation before ehos-tools#576 has them: Traefik's as they
  # are, the others' without the requests, and without the image digests 0.13.0 did not set.
  defp before_requests(%{release: "traefik", values: values}), do: values

  defp before_requests(prerequisite) do
    prerequisite
    |> before_digests()
    |> Map.delete("resources")
    |> drop_in("cainjector", "resources")
    |> drop_in("webhook", "resources")
  end

  # As 0.13.0 installed them: cert-manager's images by tag but its solver's, and trust-manager's.
  defp before_digests(%{release: release, values: values})
       when release in ["cert-manager", "trust-manager"] do
    values
    |> Map.delete("image")
    |> drop_in("cainjector", "image")
    |> drop_in("startupapicheck", "image")
    |> drop_in("webhook", "image")
  end

  defp before_digests(%{values: values}), do: values

  # As before eh-os D-143 too: without the class as well.
  defp before_class(%{release: "traefik", values: values}), do: values

  defp before_class(prerequisite) do
    prerequisite
    |> before_requests()
    |> Map.delete("priorityClassName")
    |> drop_in("global", "priorityClassName")
  end

  # `values` without `nested` under `key`, and without `key` once nothing else is under it.
  defp drop_in(values, key, nested) do
    kept = values |> Map.get(key, %{}) |> Map.delete(nested)
    if kept == %{}, do: Map.delete(values, key), else: Map.put(values, key, kept)
  end

  # The values each release was installed with whose name holds `part`.
  defp sets_matching(calls, part) do
    for {"helm", args} <- calls,
        ["upgrade", "--install", release | rest] <- [step(args)],
        into: %{} do
      set = for {"--set", value} <- Enum.zip(rest, tl(rest)), do: value
      {release, Enum.filter(set, &String.contains?(&1, part))}
    end
  end

  # Traefik's release still holding its ClusterRole and ClusterRoleBinding, every prerequisite
  # deployed or none.
  defp mock_traefik_cluster_rights(installed?) do
    record_calls(fn
      "kubectl", args ->
        if match?(["get", "clusterrole,clusterrolebinding" | _], step(args)),
          do:
            {"clusterrole.rbac.authorization.k8s.io/traefik-ehos-ingress\n" <>
               "clusterrolebinding.rbac.authorization.k8s.io/traefik-ehos-ingress\n", 0}

      program, args when installed? ->
        deployed(program, args)

      _program, _args ->
        nil
    end)
  end

  # Helm's answers for a prerequisite deployed at its pinned version with the values it is
  # installed with; nil for any other call.
  defp deployed("helm", ["list", "--namespace", namespace, "--filter", "^" <> release | _]) do
    [prerequisite] =
      Enum.filter(
        Install.prerequisite_releases(),
        &(&1.namespace == namespace and "^#{&1.release}$" == "^" <> release)
      )

    {Jason.encode!([
       %{"chart" => "#{prerequisite.name}-#{prerequisite.version}", "status" => "deployed"}
     ]), 0}
  end

  defp deployed("helm", ["get", "values", release | _]),
    do: {Jason.encode!(prerequisite(release).values), 0}

  defp deployed(_program, _args), do: nil

  # Helm's answers, in the order they are asked: the history, then a revision's values.
  defp mock_helm(answers) do
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

  # kubectl's answer to the release command, and the arguments it was run with, for the test.
  defp mock_kubectl_exec(answer) do
    test_pid = self()

    expect(CommandRunnerMock, :run_bounded, fn "kubectl", args, timeout ->
      send(test_pid, {:kubectl, args, timeout})
      answer
    end)
  end

  # The pull credential's Secret looked for in the cluster `pull_credential/1`'s test names.
  defp mock_pull_credential(answer) do
    expect(CommandRunnerMock, :run, fn "kubectl",
                                       [
                                         "--kubeconfig",
                                         "/k",
                                         "--context",
                                         "ehos-acme",
                                         "get",
                                         "secret",
                                         "ehos-pull-credential",
                                         "-n",
                                         "ehos-system",
                                         "-o",
                                         "name"
                                       ] ->
      answer
    end)
  end

  # What installed/1 reads where `running` runs and nothing else was given.
  defp installed(running),
    do: %{
      running: running,
      digest: nil,
      host: nil,
      sign_in: nil,
      four_eyes: nil,
      four_eyes_runs: nil,
      mail: nil,
      allowed_domains: nil,
      last: nil
    }

  # What installed/1 asks Helm through the installation's kubeconfig and context: the history,
  # then the deployed `revision`'s values and manifest.
  defp helm_reads(home, revision) do
    cluster = [
      "--kube-context",
      "ehos-acme",
      "--kubeconfig",
      Path.join([home, "acme", "kubeconfig"])
    ]

    [
      ["history", "ehos", "--namespace", "ehos-system"] ++ cluster ++ ["--output", "json"],
      ["get", "values", "ehos", "--namespace", "ehos-system"] ++
        cluster ++ ["--output", "json", "--revision", "#{revision}"],
      ["get", "manifest", "ehos", "--namespace", "ehos-system"] ++
        cluster ++ ["--revision", "#{revision}"]
    ]
  end

  # Why invite/1 refuses `email` before kubectl runs: `:printable`, `:form` or `:long`.
  defp not_taken(email, :printable),
    do:
      "#{inspect(email)} is not an email address EHOS takes: it holds bytes that are not " <>
        "UTF-8, a control or formatting character, or a space"

  defp not_taken(email, :form),
    do:
      "#{inspect(email)} is not an email address EHOS takes: one @ with something on each " <>
        "side, and no space, comma or semicolon"

  defp not_taken(_email, :long),
    do: "The email address is longer than the 160 characters EHOS takes"

  # A sign-in link as a failure says it, its token hidden.
  defp hidden(link), do: String.replace(link, ~r{/people/log-in/.*}, "/people/log-in/[hidden]")

  # Code without its metadata, the lines and columns it was read at.
  defp without_meta(quoted), do: Macro.prewalk(quoted, &Macro.update_meta(&1, fn _meta -> [] end))

  # Records the calls as `record_calls/1` does, answering by `answers`, and sends the test each
  # Secret applied from a file as it was when applied: `{:secret, name, contents, mode, path}`.
  defp mock_secret_files(answers \\ []) do
    test = self()

    record_calls(fn program, args ->
      with "kubectl" <- program,
           ["apply", "--server-side", "--force-conflicts", "-f", path] <- step(args) do
        contents = File.read!(path)
        %{"items" => [_namespace, %{"metadata" => %{"name" => name}}]} = Jason.decode!(contents)
        send(test, {:secret, name, contents, File.stat!(path).mode, path})
      end

      answered(answers, program, args)
    end)
  end

  # Records the calls as `record_calls/1` does, and sends the test the registry configuration
  # `chart` is pulled with, `{:registry, path, contents, mode}`, and whether the package it is
  # installed from is there then, `{:package, there?}`.
  defp mock_chart_pull(chart) do
    test = self()

    record_calls(fn
      "helm", ["pull", ^chart, "--destination", _destination | args] = all ->
        path = value_of(args, "--registry-config")
        send(test, {:registry, path, File.read!(path), File.stat!(path).mode})
        answer("helm", all)

      "helm", ["upgrade", "--install", "ehos", package | _] ->
        send(test, {:package, File.exists?(package)})
        nil

      _program, _args ->
        nil
    end)
  end

  # The installation's CA as `before` when read before its apply and once after it, then as it is
  # issued again.
  defp mock_ca_issued_again(before) do
    {:ok, reads} = Agent.start_link(fn -> 0 end)

    record_calls(fn
      "kubectl", ["--kubeconfig", _, "--context", _, "get", "secret", "ehos-local-ca" | _] ->
        case Agent.get_and_update(reads, &{&1, &1 + 1}) do
          read when read < 2 -> {Base.encode64(before), 0}
          _later -> {Base.encode64(@ca_pem), 0}
        end

      _program, _args ->
        nil
    end)
  end

  # A CloudNativePG cluster as kubectl gives it, with the priority class its spec gives.
  defp cnpg_cluster(name, class, phase \\ "Cluster in healthy state", instances \\ 1),
    do: %{
      "metadata" => %{"name" => name},
      "spec" => maybe_class(%{"instances" => instances}, class),
      "status" => %{"phase" => phase}
    }

  # An instance pod of `cluster`, running as `class`, ready or not.
  defp instance_pod(cluster, class, ready \\ "True", number \\ 1),
    do: %{
      "metadata" => %{
        "name" => "#{cluster}-#{number}",
        "labels" => %{"cnpg.io/cluster" => cluster}
      },
      "spec" => maybe_class(%{}, class),
      "status" => %{"conditions" => [%{"type" => "Ready", "status" => ready}]}
    }

  defp maybe_class(spec, nil), do: spec
  defp maybe_class(spec, class), do: Map.put(spec, "priorityClassName", class)

  defp kubectl_list(items), do: {Jason.encode!(%{"kind" => "List", "items" => items}), 0}
  defp cnpg_json(cluster), do: {Jason.encode!(cluster), 0}

  # kubectl's answers for the clusters and instance pods `listed` holds in each namespace and,
  # after a cluster's restart, for each check of it in order, `{cluster, pods}`: the last is given
  # to every check after it. Asked just before its restart, a cluster answers as `before` gives,
  # or as it was listed.
  defp mock_databases(listed, checks \\ %{}, before \\ %{}) do
    clusters =
      for {_namespace, {clusters, _pods}} <- listed,
          %{"metadata" => %{"name" => name}} = cluster <- clusters,
          into: %{},
          do: {name, cluster}

    checks =
      Map.new(checks, fn {name, answers} ->
        {name, [{cnpg_json(Map.get(before, name, clusters[name])), nil} | answers]}
      end)

    {:ok, agent} = Agent.start_link(fn -> %{checks: checks, pods: %{}} end)

    record_calls(fn
      "kubectl", args -> database_answer(step(args), listed, agent)
      _program, _args -> nil
    end)
  end

  defp database_answer(["get", "clusters.postgresql.cnpg.io", "-n", namespace | _], listed, _),
    do: listed |> Map.get(namespace, {[], []}) |> elem(0) |> kubectl_list()

  defp database_answer(
         ["get", "pods", "-n", namespace, "-l", "cnpg.io/podRole=instance" | _],
         listed,
         _
       ),
       do: listed |> Map.get(namespace, {[], []}) |> elem(1) |> kubectl_list()

  defp database_answer(["get", "clusters.postgresql.cnpg.io", name | _], _listed, agent) do
    Agent.get_and_update(agent, fn %{checks: checks, pods: pods} ->
      [{cluster, pods_answer} | rest] = Map.fetch!(checks, name)
      left = if rest == [], do: [{cluster, pods_answer}], else: rest
      {cluster, %{checks: Map.put(checks, name, left), pods: Map.put(pods, name, pods_answer)}}
    end)
  end

  defp database_answer(
         ["get", "pods", "-n", _, "-l", "cnpg.io/cluster=" <> selector | _],
         _,
         agent
       ) do
    [name | _] = String.split(selector, ",")
    Agent.get(agent, &Map.fetch!(&1.pods, name))
  end

  defp database_answer(_step, _listed, _agent), do: nil

  defp stub_now, do: stub(ClockMock, :utc_now, fn -> ~U[2026-10-31 09:15:42.123456Z] end)

  # No program is run.
  defp mock_nothing_runs,
    do: expect(CommandRunnerMock, :run, 0, fn _program, _args -> {"", 0} end)

  # What server/1 says once EHOS runs, its CA in `dir`.
  defp running(dir, opts \\ []) do
    host = Keyword.get(opts, :host, @host)
    invite = Keyword.get(opts, :invite, "mix ehos.server invite <their email>")

    "EHOS is running at https://#{host} (image ghcr.io/empoweredhouse/ehos@#{@digest}). Its " <>
      "certificate is signed by the installation's CA, in #{Path.join(dir, "ca.crt")}: trust " <>
      "it to open the console without a warning. Invite a person with `#{invite}`, which " <>
      "prints the link that signs them in: the first one invited while nobody is the " <>
      "platform's administrator becomes it."
  end

  # What server/1 runs on a cluster that answers as a fresh one does, part by part, in order: its
  # checks, the SMTP password looked for, the pull credential written, the SMTP password written,
  # the server switched from k3s's Traefik, the prerequisites, the CA and the host's name in the
  # cluster, the chart, the databases whose pods are not on their spec restarted, and the
  # governance plane restarted. An option named for a part replaces
  # its steps; `:k3s` says the cluster is k3s's, so its Traefik is looked for; `:host` and the
  # rest are `ehos_values/2`'s.
  defp server_steps(dir, opts \\ []) do
    host = Keyword.get(opts, :host, @host)
    k3s? = Keyword.get(opts, :k3s, false)

    [
      checks: checked_steps(k3s?),
      public: [console_issuer_step()],
      smtp: [],
      credential: pull_credential_steps(),
      smtp_written: [],
      switch: [],
      prerequisites: prerequisite_steps(k3s?),
      ca: ca_steps() ++ [abandoned_step()] ++ name_steps(host) ++ [ca_secret_step()],
      chart: chart_steps(ehos_values(dir, opts), Keyword.get(opts, :adopt, [])),
      databases: database_list_steps(),
      restart: []
    ]
    |> Enum.flat_map(fn {part, steps} -> Keyword.get(opts, part, steps) end)
  end

  # The issuer of the console's Certificate, which says whether EHOS runs, and with public
  # certificates (eh-os D-158).
  defp console_issuer_step,
    do:
      {:kubectl,
       [
         "get",
         "crd",
         "certificates.cert-manager.io",
         "--ignore-not-found",
         "--request-timeout=10s",
         "-o",
         "name"
       ]}

  # The console's Certificate, read once cert-manager's kind is there.
  defp console_certificate_read_step,
    do:
      {:kubectl,
       [
         "get",
         "certificates.cert-manager.io",
         "ehos-governance-tls",
         "-n",
         "ehos-system",
         "--ignore-not-found",
         "--request-timeout=10s",
         "-o",
         "jsonpath={.spec.issuerRef.name} {.spec.dnsNames[0]}"
       ]}

  # The console's Certificate with public certificates, read when the first is not there.
  defp public_certificate_read_step,
    do:
      {:kubectl,
       [
         "get",
         "certificates.cert-manager.io",
         "ehos-governance-public-tls",
         "-n",
         "ehos-system",
         "--ignore-not-found",
         "--request-timeout=10s",
         "-o",
         "jsonpath={.spec.issuerRef.name} {.spec.dnsNames[0]}"
       ]}

  # The nodes' CPUs, then whether k3s's Traefik is there to switch.
  defp checked_steps(k3s? \\ false),
    do: [
      {:kubectl, ["get", "nodes", "-o", "jsonpath={.items[*].status.allocatable.cpu}"]},
      version_step()
      | bundled_traefik_steps(k3s?)
    ]

  # The API server's own version, asked so an older Kubernetes is warned about (eh-os D-148).
  defp version_step, do: {:kubectl, ["get", "--raw", "/version", "--request-timeout=10s"]}

  # Whether the cluster is k3s's, and, on one that is, whether its Traefik's HelmCharts are there.
  defp bundled_traefik_steps(false), do: [helmcharts_crd_step()]

  defp bundled_traefik_steps(true),
    do: [
      helmcharts_crd_step(),
      {:kubectl,
       [
         "get",
         "helmchart",
         "traefik",
         "traefik-crd",
         "-n",
         "kube-system",
         "--ignore-not-found",
         "--request-timeout=10s",
         "-o",
         "jsonpath={.items[*].metadata.name}"
       ]}
    ]

  # k3s's Traefik switched out over SSH, at the tunnel's address: k3s's configuration given a
  # drop-in that adds to its `disable` list, and k3s restarted, not waited for; then the cluster
  # asked `polls` times whether its HelmCharts and their CRDs are gone.
  defp switch_steps(dir, polls, key \\ Path.join(@system_home, ".ssh/ehos_oci")) do
    ssh =
      {"ssh",
       ssh_options(key, dir) ++
         [
           "ubuntu@152.70.8.238",
           ~S|sudo -n sh -c 'set -eu; mkdir -p /etc/rancher/k3s/config.yaml.d; umask 077; | <>
             ~S|printf "disable+:\n  - traefik\n" > /etc/rancher/k3s/config.yaml.d/ehos-traefik.yaml; | <>
             ~S|systemctl restart --no-block k3s'|
         ]}

    crds =
      {:kubectl,
       [
         "get",
         "crd",
         "--request-timeout=10s",
         "-o",
         ~S|jsonpath={range .items[?(@.spec.group=="traefik.io")]}{.metadata.name} {end}|
       ]}

    [ssh | List.flatten(List.duplicate(bundled_traefik_steps(true) ++ [crds], polls))]
  end

  defp helmcharts_crd_step,
    do:
      {:kubectl,
       [
         "get",
         "crd",
         "helmcharts.helm.cattle.io",
         "--ignore-not-found",
         "--request-timeout=10s",
         "-o",
         "name"
       ]}

  defp pull_credential_steps, do: secret_steps("ehos-pull-credential")

  # Whether the cluster holds the pull credential.
  defp pull_credential_step,
    do: {:kubectl, ["get", "secret", "ehos-pull-credential", "-n", "ehos-system", "-o", "name"]}

  # A Secret applied from a file only this user reads, and the copy a client-side apply kept in
  # its annotation removed.
  defp secret_steps(name),
    do: [
      secret_apply_step(name),
      {:kubectl,
       [
         "annotate",
         "secret",
         name,
         "-n",
         "ehos-system",
         "kubectl.kubernetes.io/last-applied-configuration-"
       ]}
    ]

  defp secret_apply_step(name),
    do:
      {:kubectl, ["apply", "--server-side", "--force-conflicts", "-f", tmp(name, "secret.json")]}

  # Whether the cluster holds the SMTP password, the one it holds, and whether a run before left a
  # restart owing.
  defp smtp_held_step,
    do: {:kubectl, ["get", "secret", "ehos-smtp", "-n", "ehos-system", "-o", "name"]}

  defp smtp_password_step,
    do:
      {:kubectl,
       ["get", "secret", "ehos-smtp", "-n", "ehos-system", "-o", "jsonpath={.data.password}"]}

  defp restart_pending_step,
    do:
      {:kubectl,
       [
         "get",
         "secret",
         "ehos-smtp",
         "-n",
         "ehos-system",
         "-o",
         ~S"jsonpath={.metadata.annotations.ehos\.empowered\.house/restart}"
       ]}

  # Each namespace's CloudNativePG clusters listed, and the instance pods of one that has any.
  defp database_list_steps(pods_in \\ []),
    do:
      Enum.flat_map(["ehos-system", "ehos-data"], fn namespace ->
        [
          {:kubectl,
           [
             "get",
             "clusters.postgresql.cnpg.io",
             "-n",
             namespace,
             "--request-timeout=10s",
             "-o",
             "json"
           ]}
        ] ++
          if namespace in pods_in,
            do: [
              {:kubectl,
               [
                 "get",
                 "pods",
                 "-n",
                 namespace,
                 "-l",
                 "cnpg.io/podRole=instance",
                 "--request-timeout=10s",
                 "-o",
                 "json"
               ]}
            ],
            else: []
      end)

  # A cluster asked whether it is still healthy, then restarted, marked with the time
  # `stub_now/0` gives, to the second.
  defp database_restart_steps(namespace, name),
    do: [hd(database_poll_steps(namespace, name)), database_annotate_step(namespace, name)]

  defp database_annotate_step(namespace, name),
    do:
      {:kubectl,
       [
         "annotate",
         "clusters.postgresql.cnpg.io",
         name,
         "-n",
         namespace,
         "kubectl.kubernetes.io/restartedAt=2026-10-31T09:15:42Z",
         "--overwrite",
         "--request-timeout=10s"
       ]}

  # A restarted cluster asked about, then its instance pods.
  defp database_poll_steps(namespace, name),
    do: [
      {:kubectl,
       [
         "get",
         "clusters.postgresql.cnpg.io",
         name,
         "-n",
         namespace,
         "--request-timeout=10s",
         "-o",
         "json"
       ]},
      {:kubectl,
       [
         "get",
         "pods",
         "-n",
         namespace,
         "-l",
         "cnpg.io/cluster=#{name},cnpg.io/podRole=instance",
         "--request-timeout=10s",
         "-o",
         "json"
       ]}
    ]

  # The governance plane restarted, waited for, and the restart no longer owed.
  defp restart_steps,
    do: [
      {:kubectl, ["rollout", "restart", "deployment/ehos-governance", "-n", "ehos-system"]},
      {:kubectl,
       [
         "rollout",
         "status",
         "deployment/ehos-governance",
         "-n",
         "ehos-system",
         "--timeout",
         "10m"
       ]},
      {:kubectl,
       ["annotate", "secret", "ehos-smtp", "-n", "ehos-system", "ehos.empowered.house/restart-"]}
    ]

  # The prerequisites on a cluster that has none: the ExternalName policy, then each release
  # installed, then Traefik's rights checked.
  defp prerequisite_steps(k3s? \\ false, releases \\ fresh_release_steps()),
    do: policy_steps(k3s?) ++ releases ++ traefik_rights_steps()

  # k3s's Traefik looked for, the ExternalName policy applied, the ExternalName Services looked
  # for, and ehos-addresses made.
  defp policy_steps(k3s? \\ false),
    do:
      bundled_traefik_steps(k3s?) ++
        [
          external_names_policy_step(),
          external_names_step(),
          # eh-os#846: before Traefik, whose chart makes its Role there.
          {:kubectl, ["apply", "-f", tmp("ehos-install", "addresses-namespace.yaml")]}
        ]

  defp external_names_policy_step,
    do: {:kubectl, ["apply", "-f", tmp("ehos-install", "external-names.yaml")]}

  defp external_names_step,
    do:
      {:kubectl,
       [
         "get",
         "services",
         "--all-namespaces",
         "--field-selector",
         "spec.type=ExternalName",
         "--request-timeout=10s",
         "-o",
         ~S|jsonpath={range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}|
       ]}

  # Each prerequisite looked for, and installed.
  defp fresh_release_steps,
    do:
      release_steps("cnpg") ++
        release_steps("cert-manager") ++
        release_steps("trust-manager") ++ release_steps("traefik")

  # A prerequisite looked for, its values read when `values_read?`, and installed.
  defp release_steps(release, values_read? \\ false) do
    namespace = prerequisite(release).namespace
    read = if values_read?, do: [release_values_step(namespace, release)], else: []
    [release_list_step(namespace, release)] ++ read ++ release_install_steps(release)
  end

  # A prerequisite deployed at its pinned version with its values, waited for, not installed.
  defp deployed_release_steps(release) do
    %{namespace: namespace} = prerequisite = prerequisite(release)

    [
      release_list_step(namespace, release),
      release_values_step(namespace, release),
      {:kubectl,
       [
         "wait",
         "--for=condition=Available",
         "deployment",
         "--selector",
         "app.kubernetes.io/instance=#{Map.get(prerequisite, :instance, release)}",
         "--namespace",
         namespace,
         "--timeout=5m"
       ]}
    ]
  end

  defp release_install_steps("cnpg"),
    do: [
      {:helm,
       ["upgrade", "--install", "cnpg", chart_of("cnpg")] ++
         release_args("cnpg-system", [
           "--set",
           "priorityClassName=system-cluster-critical",
           "--set",
           "resources.requests.cpu=20m",
           "--set",
           "resources.requests.memory=80Mi"
         ]) ++ ["--wait"]}
    ]

  defp release_install_steps("cert-manager"),
    do: [
      {:helm,
       ["upgrade", "--install", "cert-manager", chart_of("cert-manager")] ++
         release_args("cert-manager", [
           "--set",
           "acmesolver.image.digest=" <>
             "sha256:699b40d622211ab7accad8a21b04c5fbaa1841ef7a12621e8de492dbe27b2503",
           "--set",
           "cainjector.image.digest=" <>
             "sha256:c85268c64f2e0e76684bf5fe8906caff34b82523561c6affe0fae3546bd87562",
           "--set",
           "cainjector.resources.requests.cpu=10m",
           "--set",
           "cainjector.resources.requests.memory=48Mi",
           "--set",
           "crds.enabled=true",
           "--set",
           "dns01RecursiveNameserversOnly=true",
           "--set",
           "enableCertificateOwnerRef=true",
           "--set",
           "global.priorityClassName=system-cluster-critical",
           "--set",
           "image.digest=" <>
             "sha256:70f532fd9cfde0b09d55687200942399d89838bc2d5d5b45152eb799a15912b8",
           "--set",
           "resources.requests.cpu=20m",
           "--set",
           "resources.requests.memory=112Mi",
           "--set",
           "startupapicheck.image.digest=" <>
             "sha256:46e75b6866359ffb5d82624f41e3ed1c70b2994982702ced547ce5edb418a8f5",
           "--set",
           "webhook.image.digest=" <>
             "sha256:a60e2dac46dbb8a7f3df95c54ce941012f54c2fe022f0ee55aaa1ab40ed957ae",
           "--set",
           "webhook.resources.requests.cpu=10m",
           "--set",
           "webhook.resources.requests.memory=48Mi"
         ]) ++ ["--wait"]}
    ]

  defp release_install_steps("trust-manager"),
    do: [
      {:helm,
       ["upgrade", "--install", "trust-manager", chart_of("trust-manager")] ++
         release_args("cert-manager", [
           "--set",
           "app.trust.namespace=cert-manager",
           "--set",
           "defaultPackage.enabled=false",
           "--set",
           "image.digest=" <>
             "sha256:0521921c2a46d14d0417336b20bcde69215ef3164f2977cc939d53c6e5224a17",
           "--set",
           "priorityClassName=system-cluster-critical",
           "--set",
           "resources.requests.cpu=10m",
           "--set",
           "resources.requests.memory=48Mi",
           "--set",
           "secretTargets.enabled=false"
         ]) ++ ["--wait"]}
    ]

  defp release_install_steps("traefik"), do: traefik_install_steps()

  # Traefik's chart pulled by its digest, its CRDs applied, not Traefik Hub's, and none taken from
  # a manager that holds them otherwise, then the chart installed without them.
  defp traefik_install_steps do
    [
      traefik_pull_step(),
      traefik_crds_step(),
      {:helm,
       ["upgrade", "--install", "traefik", tmp("ehos-traefik", "traefik")] ++
         release_args("ehos-ingress", traefik_values()) ++ ["--skip-crds", "--wait"]}
    ]
  end

  defp traefik_pull_step,
    do: {:helm, ["pull", chart_of("traefik"), "--untar", "--untardir", tmp("ehos-traefik")]}

  defp traefik_crds_step,
    do:
      {:kubectl,
       [
         "apply",
         "--server-side",
         "--field-manager=ehos-installer",
         "-f",
         tmp("ehos-traefik", "traefik/crds/traefik.io_ingressroutes.yaml"),
         "-f",
         tmp("ehos-traefik", "traefik/crds/traefik.io_middlewares.yaml")
       ]}

  defp traefik_values do
    [
      "--set",
      "api.dashboard=false",
      "--set",
      "global.checkNewVersion=false",
      "--set",
      "image.registry=docker.io",
      "--set",
      "image.repository=traefik",
      "--set",
      "image.tag=v3.7.15@sha256:0f6150202bc1fed72a7bd2107460eaa510e5b8a905f3fdb5b84f2c8619c33368",
      # eh-os#846: Roles in its two namespaces, never a ClusterRole, and no IngressClass.
      "--set",
      "ingressClass.enabled=false",
      "--set",
      "priorityClassName=system-cluster-critical",
      # A route names only a Service of its own namespace, the console's `ExternalName` too.
      "--set",
      "providers.kubernetesCRD.allowExternalNameServices=true",
      "--set",
      "providers.kubernetesCRD.crossProviderNamespaces={ehos-ingress}",
      "--set",
      "providers.kubernetesIngress.allowExternalNameServices=true",
      "--set",
      "providers.kubernetesIngress.namespaces={ehos-addresses,ehos-ingress}",
      "--set",
      "providers.kubernetesIngress.publishedService.enabled=true",
      "--set",
      "rbac.namespaced=true",
      "--set",
      "resources.requests.cpu=100m",
      "--set",
      "resources.requests.memory=64Mi",
      "--set",
      "service.spec.externalTrafficPolicy=Local"
    ]
  end

  defp release_list_step(namespace, release),
    do:
      {:helm, ["list", "--namespace", namespace, "--filter", "^#{release}$", "--output", "json"]}

  defp release_values_step(namespace, release),
    do: {:helm, ["get", "values", release, "--namespace", namespace, "--output", "json"]}

  # ehos-tools#429: Helm refuses --force-conflicts alone on a release Helm 3 applied client-side.
  defp release_args(namespace, values),
    do:
      ["--namespace", namespace, "--create-namespace", "--server-side=true", "--force-conflicts"] ++
        values

  # The chart a prerequisite is pulled from, by its digest, and the chart's version.
  defp chart_of(release), do: prerequisite(release).chart
  defp version_of(release), do: prerequisite(release).version

  defp prerequisite(release),
    do: Enum.find(Install.prerequisite_releases(), &(&1.release == release))

  # What server/1 says of an API server older than Kubernetes 1.37 (eh-os D-148).
  defp kubernetes_warning(version),
    do:
      "Warning: the cluster runs Kubernetes #{version}, older than 1.37. On it, EHOS's " <>
        "isolation policy, once deleted and made again, refuses every new environment's pods " <>
        "until the API server restarts (eh-os#923). A server made by mix ehos.server up is " <>
        "moved to 1.37 by hand once, as eh-os D-148 says, with k3s's gateway-api-crd disabled " <>
        "beside its Traefik; any other cluster is upgraded by its owner"

  # The API server's `/version` answer, as `kubectl get --raw /version` prints it.
  defp version_json(major, minor, git_version) do
    Jason.encode!(
      %{
        "major" => major,
        "minor" => minor,
        "gitVersion" => git_version,
        "platform" => "linux/arm64"
      },
      pretty: true
    )
  end

  defp cpu_warning(millicores),
    do:
      "Warning: the cluster's nodes have #{millicores}m of CPU to allocate, and EHOS's own pods " <>
        "request about 1000m of it. An application's grants Job and its rollouts may then never " <>
        "be scheduled (eh-os#892). Give the server 2 CPUs or more; on Oracle, mix ehos.server " <>
        "up --ocpus 2"

  # What server/1 says as it goes, part by part, in order, as `server_steps/2` runs it. An option
  # named for a part replaces its lines; `:host` is the console's.
  defp server_progress(opts) do
    host = Keyword.get(opts, :host, @host)

    [
      checks: [],
      credential: ["Writing the pull credential for ghcr.io (ehos-pull-credential)"],
      switch: [],
      prerequisites: [
        "Installing CloudNativePG (chart #{version_of("cnpg")})",
        "Installing cert-manager (chart #{version_of("cert-manager")})",
        "Installing trust-manager (chart #{version_of("trust-manager")})",
        "Installing Traefik (chart #{version_of("traefik")})"
      ],
      ca: [
        "Creating the installation's CA for #{host} (local-ca.yaml)",
        "Waiting for the certificate cert-manager/ehos-local-ca"
      ],
      name: ["Giving pods the name #{host} (coredns-custom.yaml)"],
      chart: [
        "Installing EHOS and waiting until it is ready",
        "Waiting for the certificate ehos-system/ehos-governance-tls"
      ]
    ]
    |> Enum.flat_map(fn {part, lines} -> Keyword.get(opts, part, lines) end)
  end

  # Asked whether Traefik's release still has cluster-wide objects, and whether its account may
  # read the cluster's Secrets: as that account, with a deadline.
  defp traefik_rights_steps,
    do: [
      {:kubectl,
       [
         "get",
         "clusterrole,clusterrolebinding",
         "--selector",
         "app.kubernetes.io/instance=traefik-ehos-ingress",
         "--request-timeout=10s",
         "-o",
         "name"
       ]},
      {:kubectl,
       [
         "auth",
         "can-i",
         "list",
         "secrets",
         "--all-namespaces",
         "--as=system:serviceaccount:ehos-ingress:traefik",
         "--request-timeout=10s"
       ]},
      {:kubectl,
       [
         "auth",
         "can-i",
         "get",
         "secrets",
         "--namespace",
         "ehos-system",
         "--as=system:serviceaccount:ehos-ingress:traefik",
         "--request-timeout=10s"
       ]}
    ]

  # The installation's CA, rendered for the host and applied, waited for and read back, and
  # `:renewed`, issued again, as `cmctl renew` does, when what it permits is not the host alone,
  # until it is; the one a cluster made before D-62 kept in ehos-system removed.
  defp ca_steps(renewed \\ nil),
    do:
      [
        ca_secret_step(),
        {:kubectl, ["apply", "-f", tmp("ehos-install", "local-ca.yaml")]},
        {:kubectl,
         [
           "wait",
           "--for=condition=Ready",
           "certificate/ehos-local-ca",
           "-n",
           "cert-manager",
           "--timeout=2m"
         ]},
        ca_secret_step()
      ] ++
        if(renewed, do: [renew_step()], else: []) ++
        [
          ca_secret_step(),
          {:kubectl,
           [
             "delete",
             "issuer/ehos-local-ca",
             "issuer/ehos-local-selfsigned",
             "certificate/ehos-local-ca",
             "secret/ehos-local-ca",
             "-n",
             "ehos-system",
             "--ignore-not-found"
           ]}
        ]

  # What a move that was abandoned may have left, looked for once the installation's CA is there.
  defp abandoned_step,
    do:
      {:kubectl,
       [
         "get",
         "certificate.cert-manager.io/ehos-governance-public-tls",
         "clusterissuer.cert-manager.io/ehos-acme-console",
         "clusterissuer.cert-manager.io/ehos-acme-addresses",
         "validatingadmissionpolicy.admissionregistration.k8s.io/ehos-acme-issuers",
         "validatingadmissionpolicybinding.admissionregistration.k8s.io/ehos-acme-issuers",
         "namespace/ehos-acme-dns",
         "-n",
         "ehos-system",
         "--ignore-not-found",
         "-o",
         "name",
         "--request-timeout=10s"
       ]}

  # Its key and name stay, so what it signed still verifies.
  defp renew_step,
    do:
      {:kubectl,
       [
         "patch",
         "certificate/ehos-local-ca",
         "-n",
         "cert-manager",
         "--subresource=status",
         "--type=merge",
         "-p",
         ~s({"status":{"conditions":[{"message":"Its name constraints permit its host alone ) <>
           ~s(and no IP address","reason":"ManuallyTriggered","status":"True","type":"Issuing"}]}})
       ]}

  defp ca_secret_step,
    do:
      {:kubectl,
       [
         "get",
         "secret",
         "ehos-local-ca",
         "-n",
         "cert-manager",
         "-o",
         ~S"jsonpath={.data.ca\.crt}"
       ]}

  # The CoreDNS rule, rendered for the host, applied, and CoreDNS rolled out by the rule's hash,
  # the same for the same rule.
  defp name_steps(host) do
    hash =
      Map.fetch!(%{@host => "1522a2964c636605", "ehos.example.org" => "6b4bf20829b43c14"}, host)

    [
      {:kubectl, ["apply", "-f", tmp("ehos-install", "coredns-custom.yaml")]},
      {:kubectl,
       [
         "patch",
         "--type=merge",
         "-p",
         ~s({"spec":{"template":{"metadata":{"annotations":{"ehos.empowered.house/coredns-rule":"#{hash}"}}}}}),
         "-n",
         "kube-system",
         "deployment/coredns"
       ]},
      {:kubectl, ["rollout", "status", "--timeout=2m", "-n", "kube-system", "deployment/coredns"]}
    ]
  end

  # A checkout's chart packaged here, the console's Certificate looked for and, by `adopt`,
  # handed over, the chart installed with `values`, and the console's certificate waited for.
  defp chart_steps(values, adopt),
    do:
      [package_step(), console_certificate_step()] ++
        adopt ++ install_chart_steps(values, "/tmp/x/ehos-0.1.0.tgz")

  # A release's chart pulled by its digest, with `registry` the registry configuration it is
  # pulled with, the console's Certificate looked for, and the chart installed from what was
  # pulled.
  defp pulled_chart_steps(chart, values, registry),
    do:
      [
        {"helm", ["pull", chart, "--destination", tmp("ehos-cluster", "chart") | registry]},
        console_certificate_step()
      ] ++ install_chart_steps(values, tmp("ehos-cluster", "chart/ehos-0.5.0.tgz"))

  defp package_step,
    do:
      {"helm", ["package", "/src/eh-os/deploy/charts/ehos", "--destination", tmp("ehos-cluster")]}

  # The package installed, rendered with the values it is installed with, in the same order.
  defp render_step(values),
    do:
      {"helm",
       ["template", "ehos", "/tmp/x/ehos-0.1.0.tgz", "--namespace", "ehos-system" | values]}

  # Handed to the release: marked as its, and freed from the Ingress.
  defp hand_over_step,
    do:
      {:kubectl,
       [
         "patch",
         "certificate",
         "ehos-governance-tls",
         "-n",
         "ehos-system",
         "--type=merge",
         "-p",
         ~s({"metadata":{"annotations":{"meta.helm.sh/release-name":"ehos",) <>
           ~s("meta.helm.sh/release-namespace":"ehos-system"},) <>
           ~s("labels":{"app.kubernetes.io/managed-by":"Helm"},"ownerReferences":null}})
       ]}

  # Its managed fields read, and, given `fields`, replaced with them at the version read.
  defp managed_fields_steps(fields \\ nil) do
    read =
      {:kubectl,
       [
         "get",
         "certificate",
         "ehos-governance-tls",
         "-n",
         "ehos-system",
         "--show-managed-fields",
         "-o",
         "jsonpath={.metadata.resourceVersion} {.metadata.managedFields}"
       ]}

    replaced =
      {:kubectl,
       [
         "patch",
         "certificate",
         "ehos-governance-tls",
         "-n",
         "ehos-system",
         "--type=json",
         "-p",
         ~s([{"op":"test","path":"/metadata/resourceVersion","value":"42"},) <>
           ~s({"op":"replace","path":"/metadata/managedFields","value":#{fields}}])
       ]}

    if fields, do: [read, replaced], else: [read]
  end

  defp console_certificate_step,
    do:
      {:kubectl,
       [
         "get",
         "certificate",
         "ehos-governance-tls",
         "-n",
         "ehos-system",
         "--ignore-not-found",
         "-o",
         "jsonpath={.metadata.name}={.metadata.ownerReferences[*].kind}"
       ]}

  defp install_chart_steps(values, package),
    do: [
      {:helm,
       [
         "upgrade",
         "--install",
         "ehos",
         package,
         "--namespace",
         "ehos-system",
         "--create-namespace",
         "--wait",
         "--timeout",
         "10m"
       ] ++ values},
      {:kubectl,
       [
         "wait",
         "--for=condition=Ready",
         "certificate/ehos-governance-tls",
         "-n",
         "ehos-system",
         "--timeout=2m"
       ]}
    ]

  # The values server/1 installs the chart with, for `:host`, the installation described as
  # `:installation` and the values `:extra` after it.
  defp ehos_values(dir, opts \\ []) do
    host = Keyword.get(opts, :host, @host)
    # D-90: an installation `up` did not make says only its name.
    installation = Keyword.get(opts, :installation, ~s({"name":"trial"}))

    chart_values(Path.join(dir, "ca.crt"), host) ++
      [
        "--set",
        "environments.imagePullSecret=ehos-pull-credential",
        "--set-json",
        "installation=#{installation}"
      ] ++
      Keyword.get(opts, :extra, []) ++ ["--set", "imagePullSecrets[0].name=ehos-pull-credential"]
  end

  # The values the chart is installed with on any installation: the image, the console's host,
  # and environments given the installation's CA, `ca_file`.
  defp chart_values(ca_file, host) do
    [
      "--set",
      "image.repository=ghcr.io/empoweredhouse/ehos",
      "--set",
      "image.digest=#{@digest}",
      "--set",
      "governance.host=#{host}",
      "--set",
      "governance.ingress.tls.secretName=ehos-governance-tls",
      "--set",
      ~S"governance.ingress.annotations.cert-manager\.io/cluster-issuer=ehos-local-ca",
      "--set",
      ~S"environments.ingress.annotations.cert-manager\.io/cluster-issuer=ehos-local-ca",
      "--set",
      "environments.ingress.tls=true",
      # eh-os D-117: environments admit Traefik from where EHOS installs it, whatever the chart
      # says.
      "--set",
      "environments.ingressController.namespace=ehos-ingress",
      "--set",
      "environments.allowedImagePrefixes={ghcr.io/empoweredhouse/}",
      "--set-file",
      "environments.caCertificate=#{ca_file}"
    ]
  end

  # The arguments after the ones that point kubectl at the cluster.
  defp step(["--kubeconfig", _, "--context", _ | rest]), do: rest
  defp step(["--context", _ | rest]), do: rest
  defp step(args), do: args

  defp value_of(args, flag), do: args |> Enum.drop_while(&(&1 != flag)) |> Enum.at(1)
end
