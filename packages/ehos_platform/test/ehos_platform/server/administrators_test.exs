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
      context = %{context(@ada) | provisioning: @ada}

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
                   bindings: ["ClusterRoleBinding ehos-administrator-ada-1a2b3c4d"]
                 },
                 %{
                   name: "bob",
                   ids: ["2b3c4d5e"],
                   keys: [AuthorizedKeys.fingerprint(@bob)],
                   bindings: []
                 },
                 %{
                   name: "shared",
                   ids: [],
                   keys: [AuthorizedKeys.fingerprint(@shared)],
                   bindings: []
                 }
               ],
               unnamed: [
                 %{
                   key: AuthorizedKeys.fingerprint(@hand),
                   comment: "kept by hand",
                   agent?: false
                 },
                 %{key: AuthorizedKeys.fingerprint(@shared), comment: "operator", agent?: true}
               ],
               others: [
                 %{binding: "ClusterRoleBinding backdoor", subject: "User mallory"},
                 %{binding: "ClusterRoleBinding wide", subject: "ServiceAccount apps/robot"}
               ],
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
                  "`admin add`."},
               {"A ClusterRoleBinding binds ehos-administrator:bob:5e6f7a8b, and no line in " <>
                  "authorized_keys has that id.",
                "Remove each user of bob with `admin remove bob`, then add them again with " <>
                  "`admin add`."}
             ]

      assert Administrators.plan_remove(state(keys, bindings), "ada", context(@ada)) ==
               {:error,
                "ehosctl did not remove ada, because ada is the last installation " <>
                  "administrator. Add another one with `admin add` first."}
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
               next: ["mix ehos.server tunnel --ssh-key PRIVATE_KEY --administrator bob"],
               warnings: [
                 {"bob runs the next command on their own workstation.",
                  "They need a copy of the folder of the installation, the state passphrase, " <>
                    "and the private key of the public key that you gave."}
               ]
             }

      assert [
               {:ssh, read, []},
               {:sh, write, written},
               {:ssh, confirm, ["-o", "ControlMaster=no", "-o", "ControlPath=none"]},
               {:sh, "sudo k3s kubectl create -f -", created}
             ] = calls()

      assert read =~ "sudo k3s kubectl get"
      assert write =~ "flock -w 120 9"
      assert confirm =~ ~s(mv "$p.pending" "$p.confirmed")

      assert written ==
               "#{@hash}\n#{keys}#{line(@bob)} ehos-administrator:bob:#{id}\n"

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
                "ehosctl changed nothing, because authorized_keys on ehos-trial changed after " <>
                  "ehosctl read it. Run the command again."}

      assert [{:ssh, _read, []}, {:sh, _write, _written}] = calls()
    end

    test "add says the server puts the file back when the new login is refused", %{
      opts: opts,
      public_key: public_key
    } do
      denied = "ubuntu@#{@address}: Permission denied (publickey).\n"

      mock_server(
        read: read_output("#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"),
        confirm: {denied, 255}
      )

      assert Administrators.add("bob", public_key, opts) ==
               {:error,
                Failure.new(
                  "The server did not take your key after the change of authorized_keys. It " <>
                    "puts the previous file back within 60 seconds. Run the command again " <>
                    "after that.",
                  "ssh",
                  denied
                )}
    end

    test "remove takes the person out of the bindings, then their line", %{opts: opts} do
      keys =
        "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n"

      mock_server(
        read: read_output(keys, [binding("ada", "1a2b3c4d"), binding("bob", "2b3c4d5e")])
      )

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
                       "state and its passphrase, an SSH session that is open, or access that " <>
                       "they made while they were an administrator. `admin list` shows each " <>
                       "binding to cluster-admin."}
                  ]
                }}

      assert [
               {:ssh, _read, []},
               {:sh, "sudo k3s kubectl delete -f -", deleted},
               {:sh, _write, written},
               {:ssh, _confirm, _fresh}
             ] = calls()

      assert Jason.decode!(deleted) == %{
               "apiVersion" => "v1",
               "kind" => "List",
               "items" => [
                 %{
                   "apiVersion" => "#{@rbac}/v1",
                   "kind" => "ClusterRoleBinding",
                   "metadata" => %{"name" => "ehos-administrator-bob-2b3c4d5e"}
                 }
               ]
             }

      assert written == "#{@hash}\n#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"
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

  defp state(keys, bindings \\ [], roles \\ [], requests \\ []) do
    %{
      hash: @hash,
      keys: AuthorizedKeys.parse(keys),
      bindings: bindings,
      roles: roles,
      requests: requests
    }
  end

  defp context(session), do: %{session: session, provisioning: @shared, provider: :oci}

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
    {"#{@hash}\n#{keys}" <>
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
        if command =~ "flock", do: {"", write}, else: {"", 0}
    end)
  end

  defp calls do
    receive do
      {kind, command, detail} -> [{kind, command, detail} | calls()]
    after
      0 -> []
    end
  end
end
