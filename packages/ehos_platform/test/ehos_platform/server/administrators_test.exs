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

    # `admin list` would tell to remove them again, and `remove` would take the new person too.
    test "refuses a name whose removal is not finished" do
      state =
        state(
          "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n# ehos-administrator-removed:bob #{line(@bob)}\n"
        )

      assert Administrators.plan_add(state, "bob", "3c4d5e6f", @hand, context(@ada)) ==
               {:error,
                "The removal of bob is not finished: GCP's guest agent can put their earlier key " <>
                  "back. Finish it with `admin remove bob`, or give the person another name."}
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
                  removed: [@ada],
                  pending: nil
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
                  removed: [@shared],
                  pending: nil
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
    # ehos-tools#1157: GCP's guest agent puts the key back whatever ehosctl writes, so the plan
    # takes out what it can, and keeps a comment with the key for a run again.
    test "removes the person, keeps a comment with their key, and says that a line of GCP's guest agent holds it" do
      agent = "# Added by Google\n#{line(@bob)} bob\n"

      state =
        state(
          "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n" <>
            agent,
          [binding("ada", "1a2b3c4d"), binding("bob", "2b3c4d5e")]
        )

      assert Administrators.plan_remove(state, "bob", %{context(@ada) | provider: :gcp}) ==
               {:ok,
                %{
                  steps: [
                    {:write_keys, @hash,
                     "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n" <>
                       agent <> "# ehos-administrator-removed:bob #{line(@bob)}\n"},
                    {:delete,
                     [
                       %{
                         "apiVersion" => "#{@rbac}/v1",
                         "kind" => "ClusterRoleBinding",
                         "metadata" => %{"name" => "ehos-administrator-bob-2b3c4d5e"}
                       }
                     ]}
                  ],
                  warnings: [one_remains("ada")],
                  removed: [@bob],
                  pending: :agent
                }}
    end

    test "says each user and place of the metadata that holds the person's key, in any form" do
      state =
        state(
          "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n",
          [binding("ada", "1a2b3c4d"), binding("bob", "2b3c4d5e")]
        )

      # A line ehosctl's parser does not read, as one with a CRLF ending and no comment, can be one
      # that the agent writes and sshd reads.
      context = %{
        context(@ada)
        | provider: :gcp,
          metadata: [
            {:instance, "ubuntu:#{line(@shared)} ubuntu\r\nbob:#{line(@bob)}\r\n"},
            {:project, "b.ob:#{line(@bob)} google-ssh {\"userName\":\"bob@example.com\"}"}
          ]
      }

      delete = %{
        "apiVersion" => "#{@rbac}/v1",
        "kind" => "ClusterRoleBinding",
        "metadata" => %{"name" => "ehos-administrator-bob-2b3c4d5e"}
      }

      assert Administrators.plan_remove(state, "bob", context) ==
               {:ok,
                %{
                  steps: [
                    {:write_keys, @hash,
                     "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n" <>
                       "# ehos-administrator-removed:bob #{line(@bob)}\n"},
                    {:delete, [delete]}
                  ],
                  warnings: [one_remains("ada")],
                  removed: [@bob],
                  pending: {:metadata, [{:instance, "bob"}, {:project, "b.ob"}]}
                }}

      clean = %{context | metadata: [{:instance, "ubuntu:#{line(@shared)} ubuntu"}]}

      assert Administrators.plan_remove(state, "bob", clean) ==
               {:ok,
                %{
                  steps: [
                    {:write_keys, @hash, "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"},
                    {:delete, [delete]}
                  ],
                  warnings: [one_remains("ada")],
                  removed: [@bob],
                  pending: nil
                }}
    end

    # The guest agent writes a key in the metadata for a user other than ubuntu into that user's
    # authorized_keys, and keeps it until its next run once the metadata no longer holds it.
    test "says when the authorized_keys of another user holds the person's key" do
      state =
        state(
          "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n"
        )

      context = %{
        context(@ada)
        | provider: :gcp,
          metadata: [{:home, "bob:#{line(@bob)} bob\nbob:"}]
      }

      assert {:ok, %{pending: {:metadata, [{:home, "bob"}]}}} =
               Administrators.plan_remove(state, "bob", context)
    end

    test "says that ehosctl could not read the metadata, also when a line of the agent holds the key" do
      state =
        state(
          "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n" <>
            "# Added by Google\n#{line(@bob)} bob\n"
        )

      unread = {:unread, "ehosctl could not read the metadata.", " Check it."}
      context = %{context(@ada) | provider: :gcp, metadata: unread}

      assert {:ok, %{pending: ^unread}} = Administrators.plan_remove(state, "bob", context)
    end

    test "on a run again, reads the comment, changes nothing while the key can come back, and drops the comment once it cannot" do
      ada = "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"
      state = state(ada <> "# ehos-administrator-removed:bob #{line(@bob)}\n")
      held = [{:project, "bob:#{line(@bob)} bob"}]
      context = %{context(@ada) | provider: :gcp}

      assert Administrators.plan_remove(state, "bob", %{context | metadata: held}) ==
               {:ok,
                %{
                  steps: [],
                  warnings: [one_remains("ada")],
                  removed: [@bob],
                  pending: {:metadata, [{:project, "bob"}]}
                }}

      assert Administrators.plan_remove(state, "bob", context) ==
               {:ok,
                %{
                  steps: [{:write_keys, @hash, ada}],
                  warnings: [one_remains("ada")],
                  removed: [@bob],
                  pending: nil
                }}
    end

    # A line of another key whose comment holds the person's blob is not a copy of their key.
    test "keeps a line of another key whose comment holds the person's key" do
      kept = "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n#{line(@hand)} was #{line(@bob)}\n"
      state = state(kept <> "#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n")

      assert Administrators.plan_remove(state, "bob", context(@ada)) ==
               {:ok,
                %{
                  steps: [{:write_keys, @hash, kept}],
                  warnings: [one_remains("ada")],
                  removed: [@bob],
                  pending: nil
                }}
    end

    test "removes a copy of the person's key on a line that ehosctl cannot read" do
      ada = "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"

      state =
        state(ada <> "#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n#{line(@bob)}\r\n", [
          binding("ada", "1a2b3c4d")
        ])

      assert Administrators.plan_remove(state, "bob", context(@ada)) ==
               {:ok,
                %{
                  steps: [{:write_keys, @hash, ada}],
                  warnings: [one_remains("ada")],
                  removed: [@bob],
                  pending: nil
                }}
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

    test "warns of a removal that is not finished, and does not count its person" do
      keys =
        "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n#{line(@hand)} ehos-administrator:cy:3c4d5e6f\n" <>
          "# ehos-administrator-removed:bob #{line(@bob)}\n"

      listing =
        Administrators.listing(
          state(keys, [binding("ada", "1a2b3c4d"), binding("cy", "3c4d5e6f")])
        )

      assert listing.warnings == [
               {"The removal of bob is not finished.",
                "GCP's guest agent can put their key on the server. Run `admin remove bob`: it " <>
                  "says the step to take, then finishes when you run it again."}
             ]

      assert Enum.map(listing.administrators, & &1.name) == ["ada", "cy"]
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
                  "Delete each such kubeconfig, and run `tunnel` again with a key of your own. " <>
                  "Then end each copy that someone kept with " <>
                  "`mix ehos.server rotate-client-ca`."}
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
                       "certificate works for up to a year, and `admin list` cannot show it. " <>
                       "`mix ehos.server rotate-client-ca` ends it."}
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

    # ehos-tools#1155: on GCP, the guest agent can write a key of the person back after the check,
    # from the file it read before or from a key put in the metadata meanwhile. Each case says what
    # finishes it: a run again finds a named line alone.
    test "remove on GCP fails, and says what it did and what to do, when a key of the person is back on a line",
         %{opts: opts} do
      File.write!(Path.join([opts[:home], "trial", "installation.json"]), ~s({"provider": "gcp"}))
      ada = "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"
      bindings = [binding("ada", "1a2b3c4d"), binding("bob", "2b3c4d5e")]

      done =
        "\nBefore this, ehosctl changed the server: wrote authorized_keys, deleted " <>
          "ClusterRoleBinding ehos-administrator-bob-2b3c4d5e."

      for {back, said, again} <- [
            {"#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n",
             "GCP's guest agent, or another program, wrote the file back.",
             " Run the command again to finish."},
            {"# Added by Google\n#{line(@bob)} bob\n",
             "GCP's guest agent wrote it, from the metadata in GCP. Remove the key from the " <>
               "metadata of the instance or of the project. The agent then removes its line.",
             ""},
            {"#{line(@bob)}\r\n",
             "Another program wrote it. Remove its line from authorized_keys on ehos-trial, as " <>
               "`admin list` shows it, before bob uses it.", ""}
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
                    "it, so bob can still log in over SSH. " <> said <> done <> again}

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

    # A comment that holds the key is not a line sshd reads.
    test "remove on GCP finishes when only a comment holds the person's key", %{opts: opts} do
      File.write!(Path.join([opts[:home], "trial", "installation.json"]), ~s({"provider": "gcp"}))
      ada = "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"
      comment = "# bob's old key: #{line(@bob)}\n"
      expect(ClockMock, :sleep, fn 2_000 -> :ok end)

      mock_server(
        read: [
          read_output(ada <> comment <> "#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n"),
          read_output(ada <> comment)
        ]
      )

      assert Administrators.remove("bob", Keyword.put(opts, :clock, ClockMock)) ==
               {:ok,
                %Report{
                  outcome: "bob is no longer an installation administrator of ehos-trial.",
                  values: [{"Line removed", "authorized_keys"}],
                  next: ["mix ehos.server admin list"],
                  warnings: [one_remains("ada"), other_ways_in("bob")]
                }}
    end

    # GCP's guest agent can write back the file it read before ehosctl's write, with the comment:
    # the write that drops it is then not in the file, and ehosctl writes again.
    test "remove on GCP writes again when the comment it dropped is back right after the write",
         %{
           opts: opts
         } do
      File.write!(Path.join([opts[:home], "trial", "installation.json"]), ~s({"provider": "gcp"}))
      ada = "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"
      marked = ada <> "# ehos-administrator-removed:bob #{line(@bob)}\n"
      expect(ClockMock, :sleep, 2, fn 2_000 -> :ok end)

      mock_server(
        read: [read_output(marked), read_output(marked), read_output(marked), &read_output(&1)],
        confirm: [{"", 77}, {"", 0}]
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
               {:ssh, _read_after_confirm, []},
               {:ssh, _read_again, []},
               {:sh, _write_again, _written_again},
               {:sh, _confirm_again, _token_again},
               {:ssh, _read_after_removal, []}
             ] = calls()
    end

    test "remove on GCP fails while the authorized_keys of another user holds the person's key",
         %{
           opts: opts
         } do
      File.write!(Path.join([opts[:home], "trial", "installation.json"]), ~s({"provider": "gcp"}))
      ada = "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"

      mock_server(
        read: read_output(ada <> "# ehos-administrator-removed:bob #{line(@bob)}\n"),
        metadata: metadata_output(%{"home/bob" => "#{line(@bob)} bob\n"})
      )

      assert Administrators.remove("bob", opts) ==
               {:error,
                "GCP's guest agent can put the key of bob on ehos-trial. The authorized_keys of " <>
                  "the user bob on the server holds it, with sudo. bob can still log in over SSH. " <>
                  "Wait until the agent removes that key, or make sure that the agent runs. Then " <>
                  "run the command again."}
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
    # writes the key into that user's authorized_keys, which ehosctl does not read. ehosctl changes
    # no metadata: it takes out what it can, fails, and finishes on a run again once the key is out
    # of the metadata.
    test "remove on GCP takes out the person, fails while the metadata holds their key for any user, and finishes on a run again",
         %{opts: opts} do
      File.write!(Path.join([opts[:home], "trial", "installation.json"]), ~s({"provider": "gcp"}))
      ada = "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"

      mock_server(
        read:
          read_output(ada <> "#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n", [
            binding("ada", "1a2b3c4d"),
            binding("bob", "2b3c4d5e")
          ]),
        metadata:
          metadata_output(%{
            "instance/attributes/ssh-keys" => "ubuntu:#{line(@shared)} ubuntu",
            "project/attributes/ssh-keys" => "bob:#{line(@bob)} google-ssh {\"userName\":\"bob\"}"
          })
      )

      assert Administrators.remove("bob", opts) ==
               {:error,
                gcp_holds_bob() <>
                  "\nBefore this, ehosctl changed the server: wrote authorized_keys, deleted " <>
                  "ClusterRoleBinding ehos-administrator-bob-2b3c4d5e. Run the command again to " <>
                  "finish."}

      assert [
               {:ssh, _metadata, []},
               {:ssh, _read, []},
               {:sh, _write, written},
               {:sh, _confirm, _token},
               {:sh, _delete, _deleted}
             ] = calls()

      [_hash, _token, marked] = String.split(written, "\n", parts: 3)
      assert marked == ada <> "# ehos-administrator-removed:bob #{line(@bob)}\n"

      # Run again while the metadata still holds the key: nothing changes.
      mock_server(
        read: read_output(marked, [binding("ada", "1a2b3c4d")]),
        metadata: metadata_output(%{"project/attributes/ssh-keys" => "bob:#{line(@bob)} bob"})
      )

      assert Administrators.remove("bob", opts) ==
               {:error, gcp_holds_bob() <> " Then run the command again."}

      assert [{:ssh, _metadata_again, []}, {:ssh, _read_again, []}] = calls()

      # Run again once the key is out of the metadata: the comment goes, and the removal holds.
      expect(ClockMock, :sleep, fn 2_000 -> :ok end)

      mock_server(
        read: [
          read_output(marked, [binding("ada", "1a2b3c4d")]),
          &read_output(&1, [binding("ada", "1a2b3c4d")])
        ]
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
               {:ssh, _metadata_last, []},
               {:ssh, _read_last, []},
               {:sh, _write_last, written_last},
               {:sh, _confirm_last, _token_last},
               {:ssh, _read_after_removal, []}
             ] = calls()

      assert [_hash, _token, ^ada] = String.split(written_last, "\n", parts: 3)
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

      for blocked <- [" true", "yes"] do
        mock_server(read: read_output(keys, bindings), metadata: metadata.(blocked))

        assert Administrators.remove("bob", opts) ==
                 {:error,
                  gcp_holds_bob() <>
                    "\nBefore this, ehosctl changed the server: wrote authorized_keys. Run the " <>
                    "command again to finish."}
      end
    end

    # A failure can come while the script prints the keys, as when the connection ends: what it
    # printed of them is left out of the error.
    test "remove on GCP takes out the person, then fails, when it cannot read the metadata", %{
      opts: opts
    } do
      File.write!(Path.join([opts[:home], "trial", "installation.json"]), ~s({"provider": "gcp"}))
      ada = "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n"
      keys = ada <> "#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n"

      printed =
        "instance/attributes/ssh-keys #{Base.encode64("bob:#{line(@bob)} bob@example.com")}\n"

      mock_server(
        read: read_output(keys),
        metadata: {printed <> "Connection reset by peer\n", 255}
      )

      assert Administrators.remove("bob", opts) ==
               {:error,
                Failure.new(
                  "ehosctl could not read the SSH keys in the metadata of ehos-trial in GCP " <>
                    "(exit status 255). So GCP's guest agent can put the key of bob back, and bob " <>
                    "can still log in over SSH. Make sure that curl and base64 run on the server, " <>
                    "and that the metadata server of GCP answers there.\nBefore this, ehosctl " <>
                    "changed the server: wrote authorized_keys. Run the command again to finish.",
                  "ssh",
                  "Connection reset by peer\n"
                )}

      mock_server(read: read_output(keys), metadata: {"instance/attributes/ssh-keys -\n", 0})

      assert Administrators.remove("bob", opts) ==
               {:error,
                "The metadata server of ehos-trial answered in a form that ehosctl cannot read. " <>
                  "So GCP's guest agent can put the key of bob back, and bob can still log in " <>
                  "over SSH. Check the values ssh-keys and sshKeys in the metadata of the " <>
                  "instance and of the project in GCP.\nBefore this, ehosctl changed the server: " <>
                  "wrote authorized_keys. Run " <>
                  "the command again to finish."}
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

    test "list warns of EHOS at zero and a copy of k3s that a rotation of the client CA left", %{
      opts: opts
    } do
      keys =
        "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n"

      mock_server(
        read: read_output(keys, [binding("ada", "1a2b3c4d"), binding("bob", "2b3c4d5e")]),
        rotation:
          rotation_output("active", "inactive", "complete", %{
            "ehos.empowered.house/client-ca-rotation-replicas" => "1"
          })
      )

      assert {:ok, %Report{warnings: warnings}} = Administrators.list(opts)

      assert warnings == [
               {"EHOS is at zero replicas on ehos-trial, because a rotation of the client CA " <>
                  "did not end.",
                "The governance plane and the operator stay stopped until it ends. Run " <>
                  "`mix ehos.server rotate-client-ca` to finish the rotation or undo it."},
               {"A copy of the keys of k3s is on the disk of ehos-trial, in /var/lib/ehosctl/client-ca.",
                "It holds each key of the cluster. Run `mix ehos.server rotate-client-ca`: it " <>
                  "finishes the rotation and deletes the copy, or undoes the rotation."}
             ]
    end

    test "list says a rotation did not end, and not that EHOS is at zero, once it scaled back", %{
      opts: opts
    } do
      keys =
        "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n"

      mock_server(
        read: read_output(keys, [binding("ada", "1a2b3c4d"), binding("bob", "2b3c4d5e")]),
        rotation:
          rotation_output(
            "active",
            "inactive",
            "none",
            %{"ehos.empowered.house/client-ca-rotation-replicas" => "1"},
            1
          )
      )

      assert {:ok, %Report{warnings: warnings}} = Administrators.list(opts)

      assert warnings == [
               {"A rotation of the client CA did not end on ehos-trial.",
                "Its annotations are still on the Deployments of EHOS. Run " <>
                  "`mix ehos.server rotate-client-ca` to finish the rotation or undo it."}
             ]
    end

    test "list does not blame a rotation for a Deployment that its owner keeps at zero", %{
      opts: opts
    } do
      keys =
        "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n"

      mock_server(
        read: read_output(keys, [binding("ada", "1a2b3c4d"), binding("bob", "2b3c4d5e")]),
        rotation:
          rotation_output(
            "active",
            "inactive",
            "none",
            %{"ehos.empowered.house/client-ca-rotation-replicas" => "0"},
            0
          )
      )

      assert {:ok,
              %Report{warnings: [{"A rotation of the client CA did not end on ehos-trial.", _}]}} =
               Administrators.list(opts)
    end

    test "list says a rotation runs, and nothing else of it", %{opts: opts} do
      keys =
        "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n"

      mock_server(
        read: read_output(keys, [binding("ada", "1a2b3c4d"), binding("bob", "2b3c4d5e")]),
        rotation: rotation_output("active", "active", "partial")
      )

      assert {:ok, %Report{warnings: warnings}} = Administrators.list(opts)

      assert warnings == [
               {"A rotation of the client CA runs on ehos-trial.",
                "Run `mix ehos.server rotate-client-ca` to follow it. EHOS stops and k3s " <>
                  "restarts while it runs."}
             ]
    end

    test "list says what a rotation left when it cannot read the administrators", %{opts: opts} do
      mock_server(
        read: {"The connection to the server 127.0.0.1:6443 was refused\n", 3},
        rotation:
          {"k3s inactive\nprocess inactive\ncopy complete\nlast -\n" <>
             "--- ehosctl client CA ---\n" <>
             "--- unread ---\nrefused\n", 0}
      )

      assert {:error, failure} = Administrators.list(opts)

      assert to_string(failure) ==
               "ehosctl could not read the administrators of ehos-trial (exit status 3).\n" <>
                 "k3s does not run on ehos-trial. If a rotation of the client CA stopped, run " <>
                 "`mix ehos.server rotate-client-ca`: it starts k3s, then finishes the rotation " <>
                 "or undoes it.\nA copy of the keys of k3s is on the disk of ehos-trial, in " <>
                 "/var/lib/ehosctl/client-ca. It holds each key of the " <>
                 "cluster. Run `mix ehos.server rotate-client-ca`: it finishes the rotation and " <>
                 "deletes the copy, or undoes the rotation.\n" <>
                 "The connection to the server 127.0.0.1:6443 was refused\n"
    end

    test "list says the read failed once when SSH fails for both reads", %{opts: opts} do
      mock_server(
        read: {"ssh: connect to host 203.0.113.7 port 22: Connection refused\n", 255},
        rotation: {"ssh: connect to host 203.0.113.7 port 22: Connection refused\n", 255}
      )

      assert Administrators.list(opts) ==
               {:error,
                Failure.new(
                  "`ssh` could not reach 203.0.113.7.",
                  "ssh",
                  "ssh: connect to host 203.0.113.7 port 22: Connection refused\n"
                )}
    end

    test "list warns when it cannot read the state of a rotation", %{opts: opts} do
      keys =
        "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n#{line(@bob)} ehos-administrator:bob:2b3c4d5e\n"

      mock_server(
        read: read_output(keys, [binding("ada", "1a2b3c4d"), binding("bob", "2b3c4d5e")]),
        rotation: {"sudo: a password is required\n", 4}
      )

      assert {:ok, %Report{warnings: warnings}} = Administrators.list(opts)

      assert warnings == [
               {"ehosctl could not read whether a rotation of the client CA runs on ehos-trial.",
                "ehosctl could not read the client CA of ehos-trial (exit status 4).\n" <>
                  "sudo: a password is required\n"}
             ]
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

  defp gcp_holds_bob,
    do:
      "GCP's guest agent can put the key of bob on ehos-trial. The metadata of the project in " <>
        "GCP holds it, for the user bob. bob can still log in over SSH. Remove the key from the " <>
        "metadata in GCP."

  defp other_ways_in(name),
    do:
      {"#{name} can still have other ways in.",
       "This does not end their access to the cloud account, their copy of the state and its " <>
         "passphrase, an SSH session that is open, or access that they made while they were an " <>
         "administrator. `admin list` shows each binding to cluster-admin. It also does not end " <>
         "a kubeconfig with the admin certificate of k3s that an earlier `tunnel` wrote for " <>
         "them. That certificate works for up to a year, and `admin list` cannot show it. " <>
         "`mix ehos.server rotate-client-ca` ends it."}

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

  # What the read of a rotation of the client CA prints: k3s runs, no process, no copy, and EHOS's
  # Deployments with `annotations`.
  defp rotation_output(
         k3s \\ "active",
         process \\ "inactive",
         copy \\ "none",
         annotations \\ %{},
         replicas \\ 0
       ) do
    deployments =
      for name <- ["ehos-governance", "ehos-operator"],
          do: %{
            "kind" => "Deployment",
            "metadata" => %{"name" => name, "annotations" => annotations},
            "spec" => %{"replicas" => replicas}
          }

    {"k3s #{k3s}\nprocess #{process}\ncopy #{copy}\nlast -\n--- ehosctl client CA ---\n" <>
       Jason.encode!(%{"items" => deployments}) <> "\n", 0}
  end

  # The server: `rotation` answers the read of a rotation of the client CA, by default with none;
  # `read` answers the read script, `write` is the exit status of the write of
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
          command =~ "--- ehosctl client CA ---" -> answer(answers, :rotation, rotation_output())
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

    homes =
      for {"home/" <> _user = name, value} <- attributes,
          into: "",
          do: "#{name} #{Base.encode64(value)}\n"

    {printed <> homes, 0}
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
