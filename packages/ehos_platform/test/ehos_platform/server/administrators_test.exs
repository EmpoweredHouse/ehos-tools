defmodule EhosPlatform.Server.AdministratorsTest do
  use ExUnit.Case, async: true

  import Hammox

  alias EhosPlatform.ClockMock
  alias EhosPlatform.CommandRunnerMock
  alias EhosPlatform.EnvMock
  alias EhosPlatform.Failure
  alias EhosPlatform.Report
  alias EhosPlatform.Server.Administrators
  alias EhosPlatform.Server.AuthorizedKeys
  alias EhosPlatform.Source

  doctest Administrators

  setup :verify_on_exit!

  @moduletag :tmp_dir

  @hash String.duplicate("a", 64)
  @address "203.0.113.7"
  @passphrase "correct horse battery staple"
  @rbac "rbac.authorization.k8s.io"
  @marker "\n--- ehosctl administrators ---\n"

  @ada {"ssh-ed25519", "AAAAC3NzaC1lZDI1NTE5AAAAIAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB"}
  @bob {"ssh-ed25519", "AAAAC3NzaC1lZDI1NTE5AAAAIAICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIC"}
  @shared {"ssh-ed25519", "AAAAC3NzaC1lZDI1NTE5AAAAIAMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMD"}
  @hand {"ssh-ed25519", "AAAAC3NzaC1lZDI1NTE5AAAAIAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE"}

  describe "plan_add/5" do
    test "adds a person beside the shared key of an installation made before, and names it shared" do
      state = state("#{line(@shared)} operator\n")

      assert Administrators.plan_add(state, "ada", "1a2b3c4d", @ada, context(@shared)) ==
               {:ok,
                %{
                  steps: [
                    {:write_keys, @hash,
                     "#{line(@shared)} ehos-administrator:shared\n" <>
                       "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"},
                    {:create, Administrators.binding("ada", "1a2b3c4d")}
                  ],
                  warnings: [one_remains("ada")]
                }, "1a2b3c4d"}
    end

    test "on GCP, adds a shared line beside the guest agent's line of the provisioning key" do
      state = state("# Added by Google\n#{line(@shared)} operator\n")
      context = %{context(@shared) | provider: :gcp}

      assert {:ok, %{steps: [{:write_keys, @hash, contents} | _binding]}, "1a2b3c4d"} =
               Administrators.plan_add(state, "ada", "1a2b3c4d", @ada, context)

      assert contents ==
               "# Added by Google\n#{line(@shared)} operator\n" <>
                 "#{line(@shared)} ehos-administrator:shared\n" <>
                 "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"
    end

    test "names the first administrator of a new server in place of cloud-init's line of their key" do
      state = state("#{line(@ada)} ada@laptop\n")
      context = %{context(@ada) | provisioning: @ada, first?: true}

      assert {:ok, %{steps: [{:write_keys, @hash, contents} | _binding]}, "1a2b3c4d"} =
               Administrators.plan_add(state, "ada", "1a2b3c4d", @ada, context)

      assert contents == "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"
    end

    test "completes an add that stopped before the binding, with the id the line holds" do
      state = state("#{line(@ada)} ehos-administrator:ada:0f0f0f0f\n")

      assert Administrators.plan_add(state, "ada", "1a2b3c4d", @ada, context(@ada)) ==
               {:ok,
                %{
                  steps: [{:create, Administrators.binding("ada", "0f0f0f0f")}],
                  warnings: [one_remains("ada")]
                }, "0f0f0f0f"}
    end

    test "makes the ClusterRoleBinding of a person bound to another role alone" do
      view = %{
        "apiVersion" => "#{@rbac}/v1",
        "kind" => "RoleBinding",
        "metadata" => %{"name" => "viewers", "namespace" => "apps"},
        "roleRef" => %{"apiGroup" => @rbac, "kind" => "ClusterRole", "name" => "view"},
        "subjects" => [user("ada", "0f0f0f0f")]
      }

      state = state("#{line(@ada)} ehos-administrator:ada:0f0f0f0f\n", [view])

      assert {:ok, %{steps: [{:create, binding}]}, "0f0f0f0f"} =
               Administrators.plan_add(state, "ada", "1a2b3c4d", @ada, context(@ada))

      assert binding == Administrators.binding("ada", "0f0f0f0f")
    end

    test "refuses the provisioning key, and a key on a line that names nobody" do
      state = state("#{line(@shared)} operator\n#{line(@hand)} kept by hand\n")

      refused =
        {:error,
         "The key in the file is on the server already, on a line that names nobody, or it is " <>
           "the provisioning key: it can be the key that every administrator shares. Each " <>
           "installation administrator has a new key of their own: give a new one."}

      for key <- [@shared, @hand] do
        assert Administrators.plan_add(state, "ada", "1a2b3c4d", key, context(@shared)) == refused
      end

      assert Administrators.plan_add(state("", []), "ada", "1a2b3c4d", @shared, context(@ada)) ==
               refused
    end

    test "refuses a name that is there, a key of another person, and a file without your key" do
      state =
        state(
          "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n",
          [binding("ada", "1a2b3c4d")]
        )

      assert Administrators.plan_add(state, "ada", "3c4d5e6f", @hand, context(@ada)) ==
               {:error,
                "ada is an installation administrator already. To give them another key, remove " <>
                  "them with `admin remove ada`, then add them again."}

      assert Administrators.plan_add(state, "carol", "3c4d5e6f", @bob, context(@ada)) ==
               {:error,
                "The key in the file is the key of bob on the server. Each installation " <>
                  "administrator has a key of their own: give a new one."}

      assert Administrators.plan_add(state, "carol", "3c4d5e6f", @hand, context(@shared)) ==
               {:error,
                "ehosctl changed nothing, because the change removes the key that you log in " <>
                  "with, #{AuthorizedKeys.fingerprint(@shared)}. Run the command from the " <>
                  "workstation of another installation administrator."}
    end
  end

  describe "plan_remove/3" do
    test "removes their line, then the person from each binding, and deletes one left empty" do
      team = %{
        "apiVersion" => "#{@rbac}/v1",
        "kind" => "RoleBinding",
        "metadata" => %{
          "name" => "team",
          "namespace" => "apps",
          "resourceVersion" => "7",
          "managedFields" => [%{}]
        },
        "roleRef" => %{"apiGroup" => @rbac, "kind" => "ClusterRole", "name" => "edit"},
        "subjects" => [user("ada", "1a2b3c4d"), %{"kind" => "Group", "name" => "devs"}]
      }

      state =
        state(
          "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n",
          [binding("ada", "1a2b3c4d"), team, binding("bob", "2b3c4d5e")]
        )

      assert Administrators.plan_remove(state, "ada", context(@bob)) ==
               {:ok,
                %{
                  steps: [
                    {:write_keys, @hash, "#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n"},
                    {:replace,
                     [
                       %{
                         team
                         | "metadata" => %{
                             "name" => "team",
                             "namespace" => "apps",
                             "resourceVersion" => "7"
                           },
                           "subjects" => [%{"kind" => "Group", "name" => "devs"}]
                       }
                     ]},
                    {:delete,
                     [
                       %{
                         "apiVersion" => "#{@rbac}/v1",
                         "kind" => "ClusterRoleBinding",
                         "metadata" => %{"name" => "ehos-administrator-ada-1a2b3c4d"}
                       }
                     ]}
                  ],
                  warnings: [one_remains("bob")],
                  removed: [@ada]
                }}
    end

    test "names each copy of the provisioning key shared, and removes each copy of a key" do
      state = state("#{line(@shared)} operator\n#{line(@shared)} copy\n")

      assert {:ok, %{steps: [{:write_keys, @hash, contents} | _]}, "1a2b3c4d"} =
               Administrators.plan_add(state, "ada", "1a2b3c4d", @ada, context(@shared))

      assert contents ==
               "#{line(@shared)} ehos-administrator:shared\n" <>
                 "#{line(@shared)} ehos-administrator:shared\n" <>
                 "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"

      # A copy of bob's key that names nobody would still log bob in.
      keys =
        "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n" <>
          "#{line(@bob)} bob@laptop\n"

      assert {:ok, %{steps: [{:write_keys, @hash, after_removal}, _delete]}} =
               Administrators.plan_remove(
                 state(keys, [binding("ada", "1a2b3c4d"), binding("bob", "2b3c4d5e")]),
                 "bob",
                 context(@ada)
               )

      assert after_removal == "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"
    end

    test "removes shared once a person has access of their own" do
      state =
        state(
          "#{line(@shared)} ehos-administrator:shared\n#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n",
          [binding("ada", "1a2b3c4d")]
        )

      assert Administrators.plan_remove(state, "shared", context(@ada)) ==
               {:ok,
                %{
                  steps: [{:write_keys, @hash, "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"}],
                  warnings: [one_remains("ada")],
                  removed: [@shared]
                }}
    end

    test "refuses the last administrator, shared before a person, and a name not there" do
      alone =
        state("#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n#{line(@shared)} operator\n", [
          binding("ada", "1a2b3c4d")
        ])

      assert Administrators.plan_remove(alone, "ada", context(@shared)) ==
               {:error,
                "ehosctl did not remove ada, because ada is the last installation " <>
                  "administrator. Add another one with `admin add` first."}

      before = state("#{line(@shared)} ehos-administrator:shared\n")

      assert Administrators.plan_remove(before, "shared", context(@shared)) ==
               {:error,
                "ehosctl did not remove shared, because no installation administrator has " <>
                  "access of their own yet. Add one with `admin add` first."}

      assert Administrators.plan_remove(alone, "carol", context(@ada)) ==
               {:error,
                "The server has no installation administrator named carol. `admin list` shows " <>
                  "who is on it."}
    end

    test "on GCP, refuses the person whose key the metadata holds" do
      state =
        state(
          "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n",
          [binding("ada", "1a2b3c4d"), binding("bob", "2b3c4d5e")]
        )

      context = %{context(@bob) | provider: :gcp, provisioning: @ada}

      assert Administrators.plan_remove(state, "ada", context) ==
               {:error,
                "ehosctl did not remove ada, because GCP's metadata holds the key of ada, and " <>
                  "GCP's guest agent writes it back. First move the provisioning key to the key " <>
                  "of another administrator with `up --provisioning-key FILE`, then remove ada."}
    end
  end

  describe "plan_remove/3 on GCP" do
    test "refuses the person whose key is on a line of GCP's guest agent" do
      state =
        state(
          "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n" <>
            "# Added by Google\n#{line(@bob)} bob\n",
          [binding("ada", "1a2b3c4d"), binding("bob", "2b3c4d5e")]
        )

      assert Administrators.plan_remove(state, "bob", %{context(@ada) | provider: :gcp}) ==
               {:error,
                "ehosctl did not remove bob, because a line of GCP's guest agent in " <>
                  "authorized_keys holds the key of bob, and the metadata that ehosctl read does " <>
                  "not. Wait until the agent removes its line, or make sure that the agent runs. " <>
                  "Then run the command again."}
    end

    test "says each place of the metadata that holds the person's key" do
      state =
        state(
          "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n",
          [binding("ada", "1a2b3c4d"), binding("bob", "2b3c4d5e")]
        )

      context = %{
        context(@ada)
        | provider: :gcp,
          metadata: [
            {:instance, "ubuntu:#{line(@shared)} ubuntu\nbob:#{line(@bob)} bob"},
            {:project, "bob:#{line(@bob)} google-ssh {\"userName\":\"bob@example.com\"}"}
          ]
      }

      assert Administrators.plan_remove(state, "bob", context) ==
               {:error,
                "ehosctl did not remove bob, because the metadata of the instance and of the " <>
                  "project in GCP holds the key of bob, and GCP's guest agent puts that key back " <>
                  "on the server. Remove the key from that metadata. Then run the command again."}

      assert {:ok, %{removed: [@bob]}} =
               Administrators.plan_remove(state, "bob", %{
                 context
                 | metadata: [{:instance, "ubuntu:#{line(@shared)} ubuntu"}]
               })
    end

    # A line that ehosctl's parser does not read, as one with a CRLF ending and no comment, can be
    # one that the agent writes and sshd reads.
    test "refuses the person whose key is in a line of the metadata that ehosctl does not read" do
      state =
        state(
          "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n",
          [binding("ada", "1a2b3c4d"), binding("bob", "2b3c4d5e")]
        )

      context = %{
        context(@ada)
        | provider: :gcp,
          metadata: [{:instance, "ubuntu:#{line(@shared)} ubuntu\r\nbob:#{line(@bob)}\r\n"}]
      }

      assert Administrators.plan_remove(state, "bob", context) ==
               {:error,
                "ehosctl did not remove bob, because the metadata of the instance in GCP holds " <>
                  "the key of bob, and GCP's guest agent puts that key back on the server. " <>
                  "Remove the key from that metadata. Then run the command again."}
    end
  end

  describe "listing/1" do
    test "shows each administrator, each key that names nobody, each other subject with every right, and the CSRs" do
      keys =
        "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n" <>
          "#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n" <>
          "#{line(@shared)} ehos-administrator:shared\n" <>
          "#{line(@hand)} kept by hand\n" <>
          "# Added by Google\n#{line(@shared)} operator\n"

      bindings = [
        binding("ada", "1a2b3c4d"),
        cluster_binding("cluster-admin", "cluster-admin", [
          %{"apiGroup" => @rbac, "kind" => "Group", "name" => "system:masters"}
        ]),
        cluster_binding("helm-kube-system-traefik", "cluster-admin", [
          %{"kind" => "ServiceAccount", "namespace" => "kube-system", "name" => "helm-traefik"}
        ]),
        cluster_binding("backdoor", "cluster-admin", [
          %{"apiGroup" => @rbac, "kind" => "User", "name" => "mallory"}
        ]),
        cluster_binding("wide", "everything", [
          %{"kind" => "ServiceAccount", "namespace" => "apps", "name" => "robot"}
        ]),
        cluster_binding("reader", "view", [
          %{"apiGroup" => @rbac, "kind" => "User", "name" => "eve"}
        ])
      ]

      roles = [
        role("everything", [%{"apiGroups" => ["*"], "resources" => ["*"], "verbs" => ["*"]}]),
        role("view", [%{"apiGroups" => [""], "resources" => ["pods"], "verbs" => ["get"]}])
      ]

      requests = [
        %{
          "metadata" => %{"name" => "ehos-administrator-ada"},
          "spec" => %{
            "username" => "ubuntu",
            "signerName" => "kubernetes.io/kube-apiserver-client"
          },
          "status" => %{"conditions" => [%{"type" => "Approved"}], "certificate" => "Q0VSVA=="}
        }
      ]

      listing = Administrators.listing(state(keys, bindings, roles, requests))

      assert listing == %{
               administrators: [
                 %{
                   name: "ada",
                   ids: ["1a2b3c4d"],
                   keys: [AuthorizedKeys.fingerprint(@ada)],
                   options: [],
                   bindings: ["ClusterRoleBinding ehos-administrator-ada-1a2b3c4d"]
                 },
                 %{
                   name: "bob",
                   ids: ["2b3c4d5e"],
                   keys: [AuthorizedKeys.fingerprint(@bob)],
                   options: [],
                   bindings: []
                 },
                 %{
                   name: "shared",
                   ids: [],
                   keys: [AuthorizedKeys.fingerprint(@shared)],
                   options: [],
                   bindings: []
                 }
               ],
               unnamed: [
                 %{
                   key: AuthorizedKeys.fingerprint(@hand),
                   comment: "kept by hand",
                   agent?: false,
                   options: nil
                 },
                 %{
                   key: AuthorizedKeys.fingerprint(@shared),
                   comment: "operator",
                   agent?: true,
                   options: nil
                 }
               ],
               others: [
                 %{binding: "ClusterRoleBinding backdoor", subject: "User mallory"},
                 %{binding: "ClusterRoleBinding wide", subject: "ServiceAccount apps/robot"}
               ],
               unreadable: [],
               requests: [
                 %{
                   name: "ehos-administrator-ada",
                   user: "ubuntu",
                   signer: "kubernetes.io/kube-apiserver-client",
                   state: "issued"
                 }
               ],
               counted: [],
               warnings: [
                 {"bob has a line in authorized_keys and no ClusterRoleBinding.",
                  "Run `admin add bob` with their key to complete it, or `admin remove bob`."}
               ]
             }
    end

    test "warns of a binding for an id that no line holds, and counts only people with a line" do
      keys = "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"

      bindings = [
        binding("ada", "1a2b3c4d"),
        binding("ada", "deadbeef"),
        binding("bob", "5e6f7a8b")
      ]

      listing = Administrators.listing(state(keys, bindings))

      assert Enum.map(listing.administrators, &{&1.name, &1.ids}) == [
               {"ada", ["1a2b3c4d", "deadbeef"]},
               {"bob", ["5e6f7a8b"]}
             ]

      assert listing.warnings == [
               one_remains("ada"),
               {"A ClusterRoleBinding binds ehos-administrator:ada:deadbeef, and no line in " <>
                  "authorized_keys has that id.",
                "Remove each user of ada with `admin remove ada`, then add them again with " <>
                  "`admin add`. If ada is the last installation administrator, add another one " <>
                  "first."},
               {"A ClusterRoleBinding binds ehos-administrator:bob:5e6f7a8b, and no line in " <>
                  "authorized_keys has that id.",
                "Remove each user of bob with `admin remove bob`, then add them again with " <>
                  "`admin add`. If bob is the last installation administrator, add another one " <>
                  "first."}
             ]

      assert Administrators.plan_remove(state(keys, bindings), "ada", context(@ada)) ==
               {:error,
                "ehosctl did not remove ada, because ada is the last installation " <>
                  "administrator. Add another one with `admin add` first."}

      # bob is in a binding alone, so nobody: removing bob leaves ada.
      assert {:ok, %{steps: [{:delete, [_bob]}]}} =
               Administrators.plan_remove(state(keys, bindings), "bob", context(@ada))
    end

    test "shows a binding named as k3s's own whose subject is not k3s's" do
      planted = [
        cluster_binding("system:monitoring", "cluster-admin", [
          %{"apiGroup" => @rbac, "kind" => "Group", "name" => "system:authenticated"}
        ]),
        cluster_binding("helm-kube-system-extra", "cluster-admin", [
          %{"kind" => "ServiceAccount", "namespace" => "kube-system", "name" => "backdoor"}
        ]),
        cluster_binding("cluster-admin", "cluster-admin", [
          %{"apiGroup" => @rbac, "kind" => "Group", "name" => "system:masters"},
          %{"apiGroup" => @rbac, "kind" => "User", "name" => "system:mallory"}
        ])
      ]

      assert Administrators.listing(state("", planted)).others == [
               %{
                 binding: "ClusterRoleBinding system:monitoring",
                 subject: "Group system:authenticated"
               },
               %{
                 binding: "ClusterRoleBinding helm-kube-system-extra",
                 subject: "ServiceAccount kube-system/backdoor"
               },
               %{binding: "ClusterRoleBinding cluster-admin", subject: "User system:mallory"}
             ]
    end

    test "hides the service accounts of the charts k3s ships alone, and shows what it cannot read" do
      bindings = [
        cluster_binding("helm-kube-system-traefik", "cluster-admin", [
          %{"kind" => "ServiceAccount", "namespace" => "kube-system", "name" => "helm-traefik"}
        ]),
        cluster_binding("helm-kube-system-x", "cluster-admin", [
          %{"kind" => "ServiceAccount", "namespace" => "kube-system", "name" => "helm-x"}
        ])
      ]

      keys =
        "cert-authority #{line(@ada)} ehos-administrator:ada:1a2b3c4d\n\v#{line(@bob)} bob\n"

      listing = Administrators.listing(state(keys, bindings))

      assert listing.others == [
               %{
                 binding: "ClusterRoleBinding helm-kube-system-x",
                 subject: "ServiceAccount kube-system/helm-x"
               }
             ]

      assert listing.unreadable == ["\v#{line(@bob)} bob"]
      assert [%{name: "ada", options: ["cert-authority"]}] = listing.administrators
    end

    test "names a line shared after its options, whatever an option or the comment quotes" do
      {type, blob} = @shared
      quoted = ~s(command="echo #{blob}" #{type} #{blob} operator #{blob}\n)
      context = %{context(@ada) | provisioning: @shared}

      assert {:ok, %{steps: [{:write_keys, @hash, contents} | _binding]}, "1a2b3c4d"} =
               Administrators.plan_add(state(quoted), "ada", "1a2b3c4d", @ada, context)

      assert contents ==
               ~s(command="echo #{blob}" #{type} #{blob} ehos-administrator:shared\n) <>
                 "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"
    end

    test "warns when no person has access of their own, and when one alone has" do
      assert Administrators.listing(state("#{line(@shared)} operator\n")).counted == [
               {"No installation administrator has access of their own.",
                "Add each person with `admin add`, with a new key of their own."}
             ]

      assert Administrators.listing(
               state("#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n", [
                 binding("ada", "1a2b3c4d")
               ])
             ).counted == [one_remains("ada")]
    end
  end

  describe "over SSH" do
    setup %{tmp_dir: tmp_dir} do
      home = Path.join(tmp_dir, "ehos")
      dir = Path.join(home, "trial")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "installation.json"), ~s({"provider": "oci"}))

      File.write!(
        Path.join(dir, "server.tfvars.json"),
        Jason.encode!(%{"ssh_public_key" => "#{line(@shared)} operator"})
      )

      key = Path.join(tmp_dir, "id_ed25519")
      File.write!(key <> ".pub", "#{line(@ada)} ada@laptop\n")
      public_key = Path.join(tmp_dir, "bob.pub")
      File.write!(public_key, "#{line(@bob)} bob@laptop\n")

      stub(EnvMock, :get, fn _name -> nil end)
      stub(EnvMock, :user_home, fn -> "/home/operator" end)

      stub(CommandRunnerMock, :run_env, fn "tofu", args, _env ->
        if "output" in args,
          do: {~s({"public_ip": {"value": "#{@address}"}}), 0},
          else: {"", 0}
      end)

      opts = [
        runner: CommandRunnerMock,
        source: Source.checkout("/src/eh-os"),
        home: home,
        ssh_key: key,
        passphrase: @passphrase,
        env: EnvMock
      ]

      %{opts: opts, public_key: public_key}
    end

    test "add writes the line, confirms it with a new login, then creates the binding", %{
      opts: opts,
      public_key: public_key
    } do
      keys = "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"
      mock_server(read: read_output(keys, [binding("ada", "1a2b3c4d")]))

      assert {:ok, %Report{values: [_key, {"Kubernetes user", user}, _binding]} = report} =
               Administrators.add("bob", public_key, opts)

      {:ok, "bob", id} = AuthorizedKeys.named(user)

      assert report == %Report{
               outcome: "bob is an installation administrator of ehos-trial.",
               values: [
                 {"Key", AuthorizedKeys.fingerprint(@bob)},
                 {"Kubernetes user", "ehos-administrator:bob:#{id}"},
                 {"ClusterRoleBinding", "ehos-administrator-bob-#{id}"}
               ],
               next: ["mix ehos.server tunnel --ssh-key PRIVATE_KEY"],
               warnings: [
                 {"bob runs the next command on their own workstation.",
                  "They need a copy of the folder of the installation, the state passphrase, " <>
                    "and the private key of the public key that you gave."}
               ]
             }

      assert [
               {:ssh, read, []},
               {:sh, write, written},
               {:sh, confirm, confirmed},
               {:sh, "sudo k3s kubectl create --request-timeout=30s -f -", created}
             ] = calls()

      # The write and its confirmation share a token of their own; the confirmation checks the file
      # is still the one written.
      [_hash, token, written_keys] = String.split(written, "\n", parts: 3)
      assert token =~ ~r/\A[0-9a-f]{16}\z/
      assert confirmed == token <> "\n" <> hash(written_keys) <> "\n"

      assert read =~ "sudo k3s kubectl get --request-timeout=30s"
      assert write =~ "flock -w 120 9"

      # The watchdog that puts the file back runs before the new file is put in place.
      [before_rename, _after] = String.split(write, ~S(mv -f "$n" "$f"))
      assert before_rename =~ "nohup sh -c"
      assert confirm =~ ~s(mv "$p.pending.$t" "$p.confirmed.$t")
      assert written =~ "#{hash(keys)}\n"
      assert written_keys == "#{keys}#{line(@bob)} ehos-administrator:bob:#{id}\n"

      assert Jason.decode!(created) == Administrators.binding("bob", id)
    end

    test "add refuses a name or a key file before it reaches the server", %{
      opts: opts,
      public_key: public_key
    } do
      expect(CommandRunnerMock, :run, 0, fn _program, _args -> {"", 0} end)

      assert Administrators.add("shared", public_key, opts) ==
               {:error,
                "shared is the name of the key that every administrator shared. Give the " <>
                  "person a name of their own."}

      assert Administrators.add("Bob", public_key, opts) ==
               {:error,
                "\"Bob\" cannot name an installation administrator. A name has 1 to 31 " <>
                  "lowercase letters, digits and hyphens, and starts with a letter."}

      File.write!(public_key, "ssh-rsa AAAA bob\n")

      assert Administrators.add("bob", public_key, opts) ==
               {:error,
                "#{public_key}: The file does not start with an ssh-ed25519 or " <>
                  "ecdsa-sha2-nistp256 public key. Give the .pub file of such a key, with no " <>
                  "options such as from= or command= before it."}
    end

    # eh-os#1836: GCP's guest agent rewrites the whole file, in another order, and keeps the lines
    # of the administrators.
    test "add reads and plans again when authorized_keys changed and kept each administrator's line",
         %{opts: opts, public_key: public_key} do
      ada = "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"
      agent = "# Added by Google\n#{line(@hand)} google-ssh\n"
      expect(ClockMock, :sleep, fn 2_000 -> :ok end)

      mock_server(read: [read_output(ada), read_output(agent <> ada)], write: [76, 0])

      assert {:ok,
              %Report{
                outcome: "bob is an installation administrator of ehos-trial.",
                values: [_key, {"Kubernetes user", "ehos-administrator:bob:" <> id}, _binding]
              }} = Administrators.add("bob", public_key, Keyword.put(opts, :clock, ClockMock))

      assert [
               {:ssh, _read, []},
               {:sh, _refused, _first},
               {:ssh, _read_again, []},
               {:sh, _write, written},
               {:sh, _confirm, _token},
               {:sh, _create, _binding}
             ] = calls()

      [hash, _token, contents] = String.split(written, "\n", parts: 3)
      assert hash == hash(agent <> ada)

      assert contents == agent <> ada <> "#{line(@bob)} ehos-administrator:bob:#{id}\n"
    end

    test "add writes nothing when the line of an administrator changed after it was read", %{
      opts: opts,
      public_key: public_key
    } do
      ada = "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"
      expect(ClockMock, :sleep, fn 2_000 -> :ok end)

      mock_server(
        read: [
          read_output(ada),
          read_output(ada <> "#{line(@hand)} ehos-administrator:cy:3c4d5e6f\n")
        ],
        write: 76
      )

      assert Administrators.add("bob", public_key, Keyword.put(opts, :clock, ClockMock)) ==
               {:error,
                "ehosctl did not change authorized_keys, because the line of an installation " <>
                  "administrator, or of shared, changed on ehos-trial after ehosctl read it. Run " <>
                  "`admin list` to see the change, then run the command again."}

      assert [{:ssh, _read, []}, {:sh, _refused, _written}, {:ssh, _read_again, []}] = calls()
    end

    test "add stops after 3 writes that each found authorized_keys changed", %{
      opts: opts,
      public_key: public_key
    } do
      expect(ClockMock, :sleep, 2, fn 2_000 -> :ok end)
      mock_server(read: read_output("#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"), write: 76)

      assert Administrators.add("bob", public_key, Keyword.put(opts, :clock, ClockMock)) ==
               {:error,
                "ehosctl did not change authorized_keys, because it changed on ehos-trial each " <>
                  "of the 3 times after ehosctl read it. Run the command again."}

      assert [
               {:ssh, _, []},
               {:sh, _, _},
               {:ssh, _, []},
               {:sh, _, _},
               {:ssh, _, []},
               {:sh, _, _}
             ] = calls()
    end

    # ehos-tools#1156: GCP's guest agent rewrites the whole file right after ehosctl's write, in
    # another order, and keeps ehosctl's lines.
    test "remove goes on to the bindings when authorized_keys changed right after the write and kept the lines as written",
         %{opts: opts} do
      ada = "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"
      agent = "# Added by Google\n#{line(@hand)} google-ssh\n"
      bindings = [binding("ada", "1a2b3c4d"), binding("bob", "2b3c4d5e")]

      mock_server(
        read: [
          read_output(
            agent <> ada <> "#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n",
            bindings
          ),
          read_output(ada <> agent, bindings)
        ],
        confirm: {"", 77}
      )

      assert Administrators.remove("bob", opts) ==
               {:ok,
                %Report{
                  outcome: "bob is no longer an installation administrator of ehos-trial.",
                  values: [
                    {"Line removed", "authorized_keys"},
                    {"Deleted", "ClusterRoleBinding ehos-administrator-bob-2b3c4d5e"}
                  ],
                  next: ["mix ehos.server admin list"],
                  warnings: [one_remains("ada"), other_ways_in("bob")]
                }}

      assert [
               {:ssh, _read, []},
               {:sh, _write, _written},
               {:sh, _confirm, _token},
               {:ssh, _read_again, []},
               {:sh, delete, _deleted}
             ] = calls()

      assert delete =~ "kubectl delete"
    end

    # eh-os#1836, ehos-tools#1156: GCP's guest agent takes no lock, and can write back what it read
    # before ehosctl's write, while the login with this workstation's key works.
    test "add writes again when GCP's guest agent wrote back the file it read before the write",
         %{
           opts: opts,
           public_key: public_key
         } do
      ada = "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"
      expect(ClockMock, :sleep, fn 2_000 -> :ok end)
      mock_server(read: read_output(ada), confirm: [{"", 77}, {"", 0}])

      assert {:ok,
              %Report{
                outcome: "bob is an installation administrator of ehos-trial.",
                values: [_key, {"Kubernetes user", "ehos-administrator:bob:" <> id}, _binding]
              }} = Administrators.add("bob", public_key, Keyword.put(opts, :clock, ClockMock))

      assert [
               {:ssh, _read, []},
               {:sh, _write, _written},
               {:sh, _confirm, _token},
               {:ssh, _read_after_confirm, []},
               {:ssh, _read_again, []},
               {:sh, _write_again, written},
               {:sh, _confirm_again, _token_again},
               {:sh, create, _binding}
             ] = calls()

      [hash, _token, contents] = String.split(written, "\n", parts: 3)
      assert hash == hash(ada)
      assert contents == ada <> "#{line(@bob)} ehos-administrator:bob:#{id}\n"
      assert create =~ "kubectl create"
    end

    test "add stops after 3 writes that each found authorized_keys changed right after the write",
         %{opts: opts, public_key: public_key} do
      expect(ClockMock, :sleep, 2, fn 2_000 -> :ok end)

      mock_server(
        read: read_output("#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"),
        confirm: {"", 77}
      )

      assert Administrators.add("bob", public_key, Keyword.put(opts, :clock, ClockMock)) ==
               {:error,
                "ehosctl did not change authorized_keys, because it changed on ehos-trial each " <>
                  "of the 3 times after ehosctl read it. Run the command again."}

      assert [
               {:ssh, _, []},
               {:sh, _, _},
               {:sh, _, _},
               {:ssh, _, []},
               {:ssh, _, []},
               {:sh, _, _},
               {:sh, _, _},
               {:ssh, _, []},
               {:ssh, _, []},
               {:sh, _, _},
               {:sh, _, _},
               {:ssh, _, []}
             ] = calls()
    end

    test "add stops before the binding when it cannot read authorized_keys after it changed right after the write",
         %{opts: opts, public_key: public_key} do
      ada = "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"
      refused = "ubuntu@#{@address}: Connection refused\n"
      mock_server(read: [read_output(ada), {refused, 255}], confirm: {"", 77})

      assert Administrators.add("bob", public_key, opts) ==
               {:error,
                Failure.new(
                  "authorized_keys changed on ehos-trial right after ehosctl wrote it, and " <>
                    "ehosctl could not read it again: `ssh` could not reach #{@address}. ehosctl " <>
                    "stopped before it changed anything else. Run the command again.",
                  "ssh",
                  refused
                )}

      assert [
               {:ssh, _read, []},
               {:sh, _write, _written},
               {:sh, _confirm, _token},
               {:ssh, _read_again, []}
             ] = calls()
    end

    # The release review of ehos_platform 0.22.0: the previous file holds a removed person's line,
    # which comes back with it.
    test "add and remove say the server puts the file back when the new login is refused", %{
      opts: opts,
      public_key: public_key
    } do
      denied = "ubuntu@#{@address}: Permission denied (publickey).\n"

      put_back =
        Failure.new(
          "The server did not take your key after the change of authorized_keys. It puts the " <>
            "previous file back within 60 seconds, so a line that this command removed, such as " <>
            "the line of an installation administrator, is back too. Run the command again " <>
            "after that.",
          "ssh",
          denied
        )

      mock_server(
        read: read_output("#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"),
        confirm: {denied, 255}
      )

      assert Administrators.add("bob", public_key, opts) == {:error, put_back}

      mock_server(
        read:
          read_output(
            "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n"
          ),
        confirm: {denied, 255}
      )

      assert Administrators.remove("bob", opts) == {:error, put_back}
    end

    # The release review of ehos_platform 0.22.0: a kubeconfig `tunnel` wrote with the shared key
    # holds k3s's admin certificate, which removing the key does not end.
    test "remove of shared says to delete its private key and the kubeconfigs it wrote", %{
      opts: opts
    } do
      keys =
        "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n#{line(@bob)} ehos-administrator:shared\n"

      bindings = [binding("ada", "1a2b3c4d")]
      mock_server(read: [read_output(keys, bindings), &read_output(&1, bindings)])

      assert {:ok, %Report{warnings: warnings}} = Administrators.remove("shared", opts)

      assert List.last(warnings) ==
               {"The key that every administrator shared can still give access.",
                "Delete its private key on each workstation that has it. A kubeconfig that " <>
                  "`tunnel` wrote with that key holds the admin certificate of k3s, which works " <>
                  "for up to a year: only a rotation of the client CA of the cluster ends it. " <>
                  "Delete each such kubeconfig, and run `tunnel` again with a key of your own."}
    end

    test "remove takes out the person's line, then their bindings", %{opts: opts} do
      keys =
        "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n"

      bob = put_in(binding("bob", "2b3c4d5e"), ["metadata", "uid"], "uid-bob")
      bob = put_in(bob, ["metadata", "resourceVersion"], "7")

      mock_server(
        read: [
          read_output(keys, [binding("ada", "1a2b3c4d"), bob]),
          &read_output(&1, [binding("ada", "1a2b3c4d")])
        ]
      )

      assert Administrators.remove("bob", opts) ==
               {:ok,
                %Report{
                  outcome: "bob is no longer an installation administrator of ehos-trial.",
                  values: [
                    {"Line removed", "authorized_keys"},
                    {"Deleted", "ClusterRoleBinding ehos-administrator-bob-2b3c4d5e"}
                  ],
                  next: ["mix ehos.server admin list"],
                  warnings: [
                    one_remains("ada"),
                    {"bob can still have other ways in.",
                     "This does not end their access to the cloud account, their copy of the " <>
                       "state and its passphrase, an SSH session that is open, or access that " <>
                       "they made while they were an administrator. `admin list` shows each " <>
                       "binding to cluster-admin. It also does not end a kubeconfig with the " <>
                       "admin certificate of k3s that an earlier `tunnel` wrote for them. That " <>
                       "certificate works for up to a year, `admin list` cannot show it, and " <>
                       "only a rotation of the client CA of the cluster ends it."}
                  ]
                }}

      assert [
               {:ssh, _read, []},
               {:sh, _write, written},
               {:sh, _confirm, _token},
               {:sh, delete, deleted}
             ] = calls()

      # Deleted with the uid and resourceVersion it was read with, so a binding changed since stays.
      assert delete =~ ~S(sudo k3s kubectl delete --request-timeout=30s --raw "$path" -f -)
      [path, options] = String.split(deleted, "\n", parts: 2)
      assert path == "/apis/#{@rbac}/v1/clusterrolebindings/ehos-administrator-bob-2b3c4d5e"

      assert Jason.decode!(options) == %{
               "apiVersion" => "v1",
               "kind" => "DeleteOptions",
               "preconditions" => %{"uid" => "uid-bob", "resourceVersion" => "7"}
             }

      [_hash, _token, rest] = String.split(written, "\n", parts: 3)
      assert rest == "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"
    end

    # ehos-tools#1155: GCP's guest agent can write back the file it read before ehosctl's write
    # after the confirmation too.
    # ehos-tools#1155: on GCP, the guest agent can write a key of the person back after the check,
    # from the file it read before or from a key someone put in the metadata meanwhile.
    test "remove on GCP fails, and says what it did, when a key of the person is back on any line",
         %{opts: opts} do
      File.write!(Path.join([opts[:home], "trial", "installation.json"]), ~s({"provider": "gcp"}))
      ada = "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"
      bindings = [binding("ada", "1a2b3c4d"), binding("bob", "2b3c4d5e")]

      for back <- [
            "#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n",
            "# Added by Google\n#{line(@bob)} bob\n",
            "#{line(@bob)}\r\n"
          ] do
        expect(ClockMock, :sleep, fn 2_000 -> :ok end)

        mock_server(
          read: [
            read_output(ada <> "#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n", bindings),
            read_output(ada <> back, bindings)
          ]
        )

        assert Administrators.remove("bob", Keyword.put(opts, :clock, ClockMock)) ==
                 {:error,
                  "A key of bob is in authorized_keys on ehos-trial again after ehosctl removed " <>
                    "it. GCP's guest agent, or another program, wrote it back. bob can still log " <>
                    "in over SSH.\nBefore this, ehosctl changed the server: wrote " <>
                    "authorized_keys, deleted ClusterRoleBinding ehos-administrator-bob-2b3c4d5e. " <>
                    "Run the command again to finish."}

        assert [
                 {:ssh, _metadata, []},
                 {:ssh, _read, []},
                 {:sh, _write, _written},
                 {:sh, _confirm, _token},
                 {:sh, _delete, _deleted},
                 {:ssh, _read_after_removal, []}
               ] = calls()
      end
    end

    test "remove on GCP reads authorized_keys again 2 seconds after the bindings", %{
      opts: opts
    } do
      File.write!(Path.join([opts[:home], "trial", "installation.json"]), ~s({"provider": "gcp"}))

      keys =
        "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n"

      test = self()

      expect(ClockMock, :sleep, fn 2_000 ->
        send(test, {:slept, 2_000, nil})
        :ok
      end)

      bindings = [binding("ada", "1a2b3c4d")]
      mock_server(read: [read_output(keys, bindings), &read_output(&1, bindings)])

      assert Administrators.remove("bob", Keyword.put(opts, :clock, ClockMock)) ==
               {:ok,
                %Report{
                  outcome: "bob is no longer an installation administrator of ehos-trial.",
                  values: [{"Line removed", "authorized_keys"}],
                  next: ["mix ehos.server admin list"],
                  warnings: [one_remains("ada"), other_ways_in("bob")]
                }}

      assert [
               {:ssh, metadata, []},
               {:ssh, _read, []},
               {:sh, _write, _written},
               {:sh, _confirm, _token},
               {:slept, 2_000, nil},
               {:ssh, _read_after_removal, []}
             ] = calls()

      assert metadata =~ "computeMetadata"
    end

    # ehos-tools#1157: the guest agent makes a user for each key in the metadata, a sudoer, and
    # writes the key into that user's authorized_keys, which ehosctl does not read.
    test "remove on GCP refuses, before it changes anything, the person whose key the metadata holds for any user",
         %{opts: opts} do
      File.write!(Path.join([opts[:home], "trial", "installation.json"]), ~s({"provider": "gcp"}))

      keys =
        "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n"

      mock_server(
        read: read_output(keys, [binding("ada", "1a2b3c4d"), binding("bob", "2b3c4d5e")]),
        metadata:
          metadata_output(%{
            "instance/attributes/ssh-keys" => "ubuntu:#{line(@shared)} ubuntu",
            "project/attributes/ssh-keys" => "bob:#{line(@bob)} google-ssh {\"userName\":\"bob\"}"
          })
      )

      assert Administrators.remove("bob", opts) ==
               {:error,
                "ehosctl did not remove bob, because the metadata of the project in GCP holds " <>
                  "the key of bob, and GCP's guest agent puts that key back on the server. " <>
                  "Remove the key from that metadata. Then run the command again."}

      assert [{:ssh, _metadata, []}, {:ssh, _read, []}] = calls()
    end

    # The guest agent reads block-project-ssh-keys with Go's strconv.ParseBool: " true" or "yes"
    # does not block the project's keys.
    test "remove on GCP ignores the project's keys only when the instance blocks them as the agent reads it",
         %{opts: opts} do
      File.write!(Path.join([opts[:home], "trial", "installation.json"]), ~s({"provider": "gcp"}))

      keys =
        "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n"

      bindings = [binding("ada", "1a2b3c4d")]

      metadata = fn blocked ->
        metadata_output(%{
          "instance/attributes/ssh-keys" => "ubuntu:#{line(@shared)} ubuntu",
          "instance/attributes/block-project-ssh-keys" => blocked,
          "project/attributes/ssh-keys" => "bob:#{line(@bob)} bob"
        })
      end

      expect(ClockMock, :sleep, fn 2_000 -> :ok end)

      mock_server(
        read: [read_output(keys, bindings), &read_output(&1, bindings)],
        metadata: metadata.("TRUE")
      )

      assert Administrators.remove("bob", Keyword.put(opts, :clock, ClockMock)) ==
               {:ok,
                %Report{
                  outcome: "bob is no longer an installation administrator of ehos-trial.",
                  values: [{"Line removed", "authorized_keys"}],
                  next: ["mix ehos.server admin list"],
                  warnings: [one_remains("ada"), other_ways_in("bob")]
                }}

      assert [
               {:ssh, _metadata, []},
               {:ssh, _read, []},
               {:sh, _write, _written},
               {:sh, _confirm, _token},
               {:ssh, _read_after_removal, []}
             ] = calls()

      for blocked <- [" true", "yes"] do
        mock_server(read: read_output(keys, bindings), metadata: metadata.(blocked))

        assert Administrators.remove("bob", opts) ==
                 {:error,
                  "ehosctl did not remove bob, because the metadata of the project in GCP " <>
                    "holds the key of bob, and GCP's guest agent puts that key back on the " <>
                    "server. Remove the key from that metadata. Then run the command again."}
      end
    end

    test "remove on GCP changes nothing when it cannot read the metadata", %{opts: opts} do
      File.write!(Path.join([opts[:home], "trial", "installation.json"]), ~s({"provider": "gcp"}))

      keys =
        "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n"

      mock_server(
        read: read_output(keys),
        metadata: {"sh: 1: curl: not found\n", 127}
      )

      assert Administrators.remove("bob", opts) ==
               {:error,
                Failure.new(
                  "ehosctl changed nothing, because it could not read the SSH keys in the " <>
                    "metadata of ehos-trial in GCP, which GCP's guest agent puts on the server " <>
                    "(exit status 127). Make sure that curl and base64 run on the server, and " <>
                    "that the metadata server of GCP answers there. Then run the command again.",
                  "ssh",
                  "sh: 1: curl: not found\n"
                )}

      mock_server(read: read_output(keys), metadata: {"instance/attributes/ssh-keys -\n", 0})

      assert Administrators.remove("bob", opts) ==
               {:error,
                "ehosctl changed nothing, because the metadata server of ehos-trial answered in " <>
                  "a form that ehosctl cannot read. Make sure that curl and base64 run on the " <>
                  "server, and that the metadata server of GCP answers there. Then run the " <>
                  "command again."}

      assert [{:ssh, _metadata, []}, {:ssh, _metadata_again, []}] = calls()
    end

    # eh-os#1836: a remove that stops between the two leaves a binding that the person cannot reach
    # without SSH, never their key on the server.
    test "remove that cannot delete the binding leaves the line removed, and finishes when run again",
         %{opts: opts} do
      ada = "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"
      bindings = [binding("ada", "1a2b3c4d"), binding("bob", "2b3c4d5e")]

      stub(CommandRunnerMock, :run, fn
        "ssh", _args ->
          read_output(ada <> "#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n", bindings)

        "sh", ["-c", _script, _input | args] ->
          if List.last(args) =~ "--raw", do: {"Unable to connect to the server", 3}, else: {"", 0}
      end)

      assert {:error, %Failure{said: said}} = Administrators.remove("bob", opts)

      assert said ==
               "kubectl delete failed on ehos-trial. If ClusterRoleBinding " <>
                 "ehos-administrator-bob-2b3c4d5e changed since ehosctl read it, run the command " <>
                 "again (exit status 3).\nBefore this, ehosctl changed the server: wrote " <>
                 "authorized_keys. Run the command again to finish."

      mock_server(read: read_output(ada, bindings))

      assert {:ok,
              %Report{values: [{"Deleted", "ClusterRoleBinding ehos-administrator-bob-2b3c4d5e"}]}} =
               Administrators.remove("bob", opts)

      assert [{:ssh, _read, []}, {:sh, delete, _deleted}] = calls()
      assert delete =~ "kubectl delete"
    end

    test "add and remove say each step they did before a later one failed", %{
      opts: opts,
      public_key: public_key
    } do
      test = self()
      keys = "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"

      # add: the line is written, then the binding is refused.
      mock_server(read: read_output(keys))

      stub(CommandRunnerMock, :run, fn
        "ssh", args -> if List.last(args) =~ "kubectl get", do: read_output(keys), else: {"", 0}
        "sh", ["-c", _script, _input | args] -> kubectl_or_write(test, List.last(args))
      end)

      assert {:error, %Failure{said: said}} = Administrators.add("bob", public_key, opts)
      assert said =~ "\nBefore this, ehosctl changed the server: wrote authorized_keys. Run"

      # remove: the first binding is deleted, the second refused.
      both =
        "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n"

      bindings = [
        binding("ada", "1a2b3c4d"),
        binding("bob", "2b3c4d5e"),
        binding("bob", "3c4d5e6f")
      ]

      Process.put(:deletes, 0)

      stub(CommandRunnerMock, :run, fn
        "ssh", _args ->
          read_output(both, bindings)

        "sh", ["-c", _script, _input | args] ->
          if List.last(args) =~ "--raw" do
            Process.put(:deletes, Process.get(:deletes) + 1)
            if Process.get(:deletes) == 1, do: {"", 0}, else: {"Precondition failed", 3}
          else
            {"", 0}
          end
      end)

      assert {:error, %Failure{said: said}} = Administrators.remove("bob", opts)

      assert said =~
               "\nBefore this, ehosctl changed the server: wrote authorized_keys, deleted " <>
                 "ClusterRoleBinding ehos-administrator-bob-2b3c4d5e. Run"
    end

    test "list says what the server holds", %{opts: opts} do
      keys = "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n#{line(@shared)} operator\n"
      mock_server(read: read_output(keys, [binding("ada", "1a2b3c4d")]))

      assert Administrators.list(opts) ==
               {:ok,
                %Report{
                  outcome: "ehos-trial has 1 installation administrator.",
                  values: [
                    {"ada",
                     "id 1a2b3c4d, key #{AuthorizedKeys.fingerprint(@ada)}, " <>
                       "ClusterRoleBinding ehos-administrator-ada-1a2b3c4d"},
                    {"Unnamed key", "#{AuthorizedKeys.fingerprint(@shared)} operator"}
                  ],
                  warnings: [one_remains("ada")]
                }}
    end

    test "reads a file that holds the marker of the answer, and refuses one that is not whole" do
      keys = "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n--- ehosctl administrators ---\n"
      {output, 0} = read_output(keys)

      assert {:ok, %{keys: [%{name: "ada"}, %{kind: :unreadable}]}} =
               Administrators.parse_state(output)

      cut = String.replace(output, Base.encode64(keys), Base.encode64(binary_part(keys, 0, 20)))

      assert Administrators.parse_state(cut) ==
               {:error, "The server answered in a form that ehosctl cannot read."}
    end

    test "list counts only the people with a line, not a name in a binding alone", %{opts: opts} do
      keys = "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"

      mock_server(
        read: read_output(keys, [binding("ada", "1a2b3c4d"), binding("bob", "5e6f7a8b")])
      )

      assert {:ok, %Report{outcome: "ehos-trial has 1 installation administrator."}} =
               Administrators.list(opts)
    end

    test "list says when the server answers what ehosctl cannot read", %{opts: opts} do
      mock_server(read: {"sudo: k3s: command not found\n", 3})

      assert Administrators.list(opts) ==
               {:error,
                Failure.new(
                  "ehosctl could not read the administrators of ehos-trial (exit status 3).",
                  "ssh",
                  "sudo: k3s: command not found\n"
                )}
    end
  end

  defp hash(keys), do: Base.encode16(:crypto.hash(:sha256, keys), case: :lower)

  defp state(keys, bindings \\ [], roles \\ [], requests \\ []) do
    %{
      hash: @hash,
      keys: AuthorizedKeys.parse(keys),
      bindings: bindings,
      roles: roles,
      requests: requests
    }
  end

  defp context(session),
    do: %{session: session, provisioning: @shared, provider: :oci, first?: false, metadata: []}

  defp binding(name, id), do: Administrators.binding(name, id)

  defp user(name, id),
    do: %{"apiGroup" => @rbac, "kind" => "User", "name" => "ehos-administrator:#{name}:#{id}"}

  defp cluster_binding(name, role, subjects) do
    %{
      "apiVersion" => "#{@rbac}/v1",
      "kind" => "ClusterRoleBinding",
      "metadata" => %{"name" => name},
      "roleRef" => %{"apiGroup" => @rbac, "kind" => "ClusterRole", "name" => role},
      "subjects" => subjects
    }
  end

  defp role(name, rules),
    do: %{"kind" => "ClusterRole", "metadata" => %{"name" => name}, "rules" => rules}

  defp line({type, blob}), do: "#{type} #{blob}"

  defp other_ways_in(name),
    do:
      {"#{name} can still have other ways in.",
       "This does not end their access to the cloud account, their copy of the state and its " <>
         "passphrase, an SSH session that is open, or access that they made while they were an " <>
         "administrator. `admin list` shows each binding to cluster-admin. It also does not end " <>
         "a kubeconfig with the admin certificate of k3s that an earlier `tunnel` wrote for " <>
         "them. That certificate works for up to a year, `admin list` cannot show it, and only " <>
         "a rotation of the client CA of the cluster ends it."}

  defp one_remains(name),
    do:
      {"One installation administrator remains: #{name}.",
       "If #{name} loses their key, nobody can reach the server over SSH. Add a second one " <>
         "with `admin add`."}

  # What the read script prints for `keys` and `bindings`, with no roles and no CSRs.
  defp read_output(keys, bindings \\ []) do
    {"#{hash(keys)}\n#{Base.encode64(keys)}" <>
       @marker <>
       Jason.encode!(%{"items" => bindings}) <>
       @marker <> ~s({"items": []}) <> @marker <> ~s({"items": []}) <> "\n", 0}
  end

  # The server: `read` answers the read script, `write` is the exit status of the write of
  # authorized_keys, `confirm` answers the new login, `metadata` answers the read of GCP's metadata,
  # by default with the provisioning key alone, and kubectl succeeds. `read`, `write` and
  # `confirm` can be lists, answered in turn, the last one again. A `read` that is a function is
  # given the file of the last write, for an answer that holds a line with the id `add` made. Each
  # call is recorded as `{:ssh, command, options after the default ones}` or
  # `{:sh, command, input}`.
  defp mock_server(answers) do
    test = self()
    Enum.each([:read, :write, :confirm], &Process.delete({:answered, &1}))

    stub(CommandRunnerMock, :run, fn
      "ssh", args ->
        {options, ["ubuntu@" <> _address, command]} = Enum.split(args, -2)
        send(test, {:ssh, command, Enum.drop(options, 20)})

        cond do
          command =~ "sudo k3s kubectl get" -> answers |> answer(:read) |> read_answer()
          command =~ "computeMetadata" -> answer(answers, :metadata, metadata_output())
          true -> answer(answers, :confirm, {"", 0})
        end

      "sh", ["-c", ~S(exec ssh "$@" <"$0"), input | args] ->
        command = List.last(args)
        input = File.read!(input)
        send(test, {:sh, command, input})

        cond do
          command =~ "flock" -> written(input, answer(answers, :write, 0))
          command =~ "confirmed" -> answer(answers, :confirm, {"", 0})
          true -> {"", 0}
        end
    end)
  end

  # What the metadata script prints: each attribute in base64, or `-` when it is not set.
  defp metadata_output(
         attributes \\ %{"instance/attributes/ssh-keys" => "ubuntu:#{line(@shared)} ubuntu"}
       ) do
    printed =
      for attribute <- [
            "instance/attributes/ssh-keys",
            "instance/attributes/sshKeys",
            "instance/attributes/block-project-ssh-keys",
            "project/attributes/ssh-keys",
            "project/attributes/sshKeys"
          ],
          into: "" do
        value = attributes[attribute]
        "#{attribute} #{if value, do: Base.encode64(value), else: "-"}\n"
      end

    {printed, 0}
  end

  defp read_answer(read) when is_function(read, 1), do: read.(Process.get(:written))
  defp read_answer(read), do: read

  defp written(input, status) do
    [_hash, _token, contents] = String.split(input, "\n", parts: 3)
    Process.put(:written, contents)
    {"", status}
  end

  defp answer(answers, key, default \\ nil) do
    case Keyword.get(answers, key, default) do
      [_ | _] = each ->
        answered = Process.get({:answered, key}, 0)
        Process.put({:answered, key}, answered + 1)
        Enum.at(each, answered, List.last(each))

      one ->
        one
    end
  end

  # The write and the confirmation succeed; kubectl create is refused.
  defp kubectl_or_write(test, command) do
    send(test, {:sh, command, nil})
    if command =~ "kubectl create", do: {"forbidden", 1}, else: {"", 0}
  end

  defp calls do
    receive do
      {kind, command, detail} -> [{kind, command, detail} | calls()]
    after
      0 -> []
    end
  end
end
