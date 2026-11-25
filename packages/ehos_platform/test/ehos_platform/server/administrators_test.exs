defmodule EhosPlatform.Server.AdministratorsTest do
  use ExUnit.Case, async: true

  import Hammox

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
    test "removes the person from each binding, deletes one left empty, then removes their line" do
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
                     ]},
                    {:write_keys, @hash, "#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n"}
                  ],
                  warnings: [one_remains("bob")]
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

      assert {:ok, %{steps: [_delete, {:write_keys, @hash, after_removal}]}} =
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
                  warnings: [one_remains("ada")]
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

      # The write and its confirmation share a token of their own.
      [_hash, token, written_keys] = String.split(written, "\n", parts: 3)
      assert token =~ ~r/\A[0-9a-f]{16}\z/
      assert confirmed == token <> "\n"

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

    test "add changes nothing when authorized_keys changed after it was read", %{
      opts: opts,
      public_key: public_key
    } do
      mock_server(read: read_output("#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"), write: 76)

      assert Administrators.add("bob", public_key, opts) ==
               {:error,
                "ehosctl did not change authorized_keys, because it changed on ehos-trial after " <>
                  "ehosctl read it. Run the command again."}

      assert [{:ssh, _read, []}, {:sh, _write, _written}] = calls()
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
            "previous file back within 60 seconds, so a line that this command removed, as an " <>
            "installation administrator's, is back too. Run the command again after that.",
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

      assert {:error, %Failure{said: said}} = Administrators.remove("bob", opts)
      assert said =~ put_back.said
    end

    # The release review of ehos_platform 0.22.0: a kubeconfig `tunnel` wrote with the shared key
    # holds k3s's admin certificate, which removing the key does not end.
    test "remove of shared says to delete its private key and the kubeconfigs it wrote", %{
      opts: opts
    } do
      keys =
        "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n#{line(@bob)} ehos-administrator:shared\n"

      mock_server(read: read_output(keys, [binding("ada", "1a2b3c4d")]))

      assert {:ok, %Report{warnings: warnings}} = Administrators.remove("shared", opts)

      assert List.last(warnings) ==
               {"The key that every administrator shared can still give access.",
                "Delete its private key on each workstation that has it. A kubeconfig that " <>
                  "`tunnel` wrote with that key holds the admin certificate of k3s, which works " <>
                  "for up to a year: only a rotation of the client CA of the cluster ends it. " <>
                  "Delete each such kubeconfig, and run `tunnel` again with a key of your own."}
    end

    test "remove takes the person out of the bindings, then their line", %{opts: opts} do
      keys =
        "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n"

      bob = put_in(binding("bob", "2b3c4d5e"), ["metadata", "uid"], "uid-bob")
      bob = put_in(bob, ["metadata", "resourceVersion"], "7")
      mock_server(read: read_output(keys, [binding("ada", "1a2b3c4d"), bob]))

      assert Administrators.remove("bob", opts) ==
               {:ok,
                %Report{
                  outcome: "bob is no longer an installation administrator of ehos-trial.",
                  values: [
                    {"Deleted", "ClusterRoleBinding ehos-administrator-bob-2b3c4d5e"},
                    {"Line removed", "authorized_keys"}
                  ],
                  next: ["mix ehos.server admin list"],
                  warnings: [
                    one_remains("ada"),
                    {"bob can still have other ways in.",
                     "This does not end their access to the cloud account, their copy of the " <>
                       "state and its passphrase, an SSH session that is open, a kubeconfig " <>
                       "with the admin certificate of k3s that an earlier `tunnel` wrote for " <>
                       "them, or access that they made while they were an administrator. That " <>
                       "certificate works for up to a year, and only a rotation of the client " <>
                       "CA of the cluster ends it. `admin list` shows each binding to " <>
                       "cluster-admin, but not that certificate."}
                  ]
                }}

      assert [
               {:ssh, _read, []},
               {:sh, delete, deleted},
               {:sh, _write, written},
               {:sh, _confirm, _token}
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

    test "remove says what it changed before authorized_keys changed under it", %{opts: opts} do
      keys =
        "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n"

      mock_server(
        read: read_output(keys, [binding("ada", "1a2b3c4d"), binding("bob", "2b3c4d5e")]),
        write: 76
      )

      assert Administrators.remove("bob", opts) ==
               {:error,
                "ehosctl did not change authorized_keys, because it changed on ehos-trial after " <>
                  "ehosctl read it. Run the command again.\nBefore this, ehosctl changed the " <>
                  "server: deleted ClusterRoleBinding ehos-administrator-bob-2b3c4d5e. Run the " <>
                  "command again to finish."}
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
               "\nBefore this, ehosctl changed the server: deleted ClusterRoleBinding " <>
                 "ehos-administrator-bob-2b3c4d5e. Run"
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
    do: %{session: session, provisioning: @shared, provider: :oci, first?: false}

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
  # authorized_keys, `confirm` answers the new login, and kubectl succeeds. Each call is recorded
  # as `{:ssh, command, options after the default ones}` or `{:sh, command, input}`.
  defp mock_server(answers) do
    test = self()
    write = Keyword.get(answers, :write, 0)
    confirm = Keyword.get(answers, :confirm, {"", 0})

    stub(CommandRunnerMock, :run, fn
      "ssh", args ->
        {options, ["ubuntu@" <> _address, command]} = Enum.split(args, -2)
        send(test, {:ssh, command, Enum.drop(options, 20)})
        if command =~ "sudo k3s kubectl get", do: answers[:read], else: confirm

      "sh", ["-c", ~S(exec ssh "$@" <"$0"), input | args] ->
        command = List.last(args)
        send(test, {:sh, command, File.read!(input)})

        cond do
          command =~ "flock" -> {"", write}
          command =~ "confirmed" -> confirm
          true -> {"", 0}
        end
    end)
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
