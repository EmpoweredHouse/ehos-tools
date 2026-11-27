defmodule EhosPlatform.Server.ClientCaTest do
  use ExUnit.Case, async: true

  import Hammox

  alias EhosPlatform.ClockMock
  alias EhosPlatform.CommandRunnerMock
  alias EhosPlatform.EnvMock
  alias EhosPlatform.Failure
  alias EhosPlatform.Report
  alias EhosPlatform.Server.ClientCa
  alias EhosPlatform.Source

  doctest ClientCa

  setup :verify_on_exit!

  @moduletag :tmp_dir

  @address "203.0.113.7"
  @passphrase "correct horse battery staple"
  @marker "\n--- ehosctl administrators ---\n"
  @annotation "ehos.empowered.house/client-ca-rotation-"
  @began ~U[2026-11-26 10:00:00Z]

  @ada {"ssh-ed25519", "AAAAC3NzaC1lZDI1NTE5AAAAIAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB"}
  @bob {"ssh-ed25519", "AAAAC3NzaC1lZDI1NTE5AAAAIAICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIC"}
  @shared {"ssh-ed25519", "AAAAC3NzaC1lZDI1NTE5AAAAIAMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMD"}

  describe "decide/2" do
    test "starts the rotation on a server with both Deployments of EHOS and nothing begun" do
      assert ClientCa.decide(status(), "trial") == {:ok, :start}
    end

    test "follows the process that runs" do
      assert ClientCa.decide(%{status() | process?: true, copy: :complete}, "trial") ==
               {:ok, :follow}
    end

    test "starts again when a copy, a stopped k3s or an annotation shows a rotation began" do
      assert ClientCa.decide(%{status() | copy: :partial}, "trial") == {:ok, :again}
      assert ClientCa.decide(%{status() | copy: :complete}, "trial") == {:ok, :again}

      assert ClientCa.decide(
               %{status() | k3s?: false, deployments: {:unread, "refused"}},
               "trial"
             ) ==
               {:ok, :again}

      annotated = [
        deployment("ehos-governance", %{"#{@annotation}replicas" => "1"}),
        deployment("ehos-operator")
      ]

      assert ClientCa.decide(%{status() | deployments: annotated}, "trial") == {:ok, :again}
    end

    test "refuses a first start without both Deployments of EHOS" do
      assert ClientCa.decide(%{status() | deployments: [deployment("ehos-operator")]}, "trial") ==
               {:error,
                "ehos-trial has no Deployment ehos-governance in ehos-system, so ehosctl did " <>
                  "not start the rotation: it records the rotation on the Deployments of EHOS. " <>
                  "Install EHOS with `install`, then run the command again."}
    end

    test "refuses a first start when it cannot read the Deployments of EHOS" do
      assert ClientCa.decide(%{status() | deployments: {:unread, "Unauthorized\n"}}, "trial") ==
               {:error,
                Failure.new(
                  "ehosctl could not read the Deployments of EHOS on ehos-trial, so it did not " <>
                    "start the rotation. Make sure that k3s runs, then run the command again.",
                  "kubectl",
                  "Unauthorized\n"
                )}
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

      stub(EnvMock, :get, fn _name -> nil end)
      stub(EnvMock, :user_home, fn -> "/home/operator" end)

      stub(CommandRunnerMock, :run_env, fn "tofu", args, _env ->
        if "output" in args,
          do: {~s({"public_ip": {"value": "#{@address}"}}), 0},
          else: {"", 0}
      end)

      test = self()
      Process.put(:now, @began)
      stub(ClockMock, :sleep, fn 5_000 -> :ok end)
      stub(ClockMock, :utc_now, fn -> Process.get(:now) end)

      opts = [
        runner: CommandRunnerMock,
        source: Source.checkout("/src/eh-os"),
        home: home,
        ssh_key: key,
        passphrase: @passphrase,
        env: EnvMock,
        clock: ClockMock,
        progress: &send(test, {:progress, &1})
      ]

      %{opts: opts}
    end

    test "starts the rotation as a unit of its own, follows its log and reports the new CA", %{
      opts: opts
    } do
      mock_server(
        polls: [
          fn run -> poll("active", "-", "run #{run}\nstep space\nstep scale-") end,
          fn _run -> poll("active", "-", "step scale-down\nstep rotate-ca\n") end,
          fn run -> poll("inactive", "#{run} finished -", "step unannotate\n") end
        ]
      )

      assert ClientCa.rotate(opts) ==
               {:ok,
                %Report{
                  outcome:
                    "ehos-trial has a new client CA. The certificates of the old client CA no " <>
                      "longer work.",
                  values: [
                    {"Ended", "the admin certificate of k3s that `tunnel` copied before"},
                    {"Ended", "the certificate of each installation administrator"},
                    {"Replaced", "the server token of k3s"}
                  ],
                  next: ["mix ehos.server tunnel"],
                  warnings: [
                    {"Each installation administrator runs `tunnel` again.",
                     "Their certificate was from the old client CA. `tunnel` issues a new one."},
                    {"The rotation does not end each other way in.",
                     "It keeps the server CA, the request-header CA and the key of the service " <>
                       "accounts. A ServiceAccount token, a binding or a workload that someone " <>
                       "made still works. `admin list` shows each binding to cluster-admin."}
                  ]
                }}

      assert [
               {:ssh, status, nil},
               {:ssh, read, nil},
               {:sh, start, started},
               {:sh, follow, first},
               {:sh, follow, second},
               {:sh, follow, third}
             ] = calls()

      # The offset read so far, and the run it follows: its own.
      run = started |> String.split("\n") |> hd()
      assert [first, second, third] == ["0\n#{run}\n", "32\n#{run}\n", "63\n#{run}\n"]

      assert status =~ "systemctl is-active ehosctl-client-ca.service"
      assert read =~ "--- ehosctl administrators ---"
      assert start =~ "systemd-run --unit=ehosctl-client-ca"
      # A lock holds a start at the same moment off; each run has a script file of its own.
      assert start =~ "flock -n -E 12"
      # Each run has its own log and result, and `current` names the last one that began.
      assert start =~ ~S|printf "%s\n" "$run" >"$d/current.new"|
      assert start =~ ~S|/bin/sh "$d/process-$run.sh"|
      assert follow =~ ~S|tail -c "+$((offset + 1))"|

      # The id of the run, the mode, the last run it read, then the process's script, which the unit runs with both.
      [run, "start", "-", script] = String.split(started, "\n", parts: 4)
      assert run =~ ~r/\A[0-9a-f]{16}\z/
      assert script == ClientCa.process_script()

      assert progress() == [
               "Starting the rotation of the client CA on ehos-trial",
               "Checking the room on the disk for a copy of k3s",
               "Scaling the governance plane and the operator of EHOS to zero",
               "Replacing the client CA with `k3s certificate rotate-ca`",
               "Removing the annotations of the rotation"
             ]
    end

    test "refuses a first start while the server keeps the shared key, and starts nothing", %{
      opts: opts
    } do
      mock_server(
        keys:
          "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n#{line(@shared)} ehos-administrator:shared\n"
      )

      assert ClientCa.rotate(opts) ==
               {:error,
                "ehos-trial still has the key that every installation administrator shared, so " <>
                  "ehosctl did not start the rotation. With that key, a person can copy the " <>
                  "admin certificate of k3s again. Remove it with " <>
                  "`mix ehos.server admin remove shared`, then run the command again. On GCP, " <>
                  "first give the key of an installation administrator to " <>
                  "`up --provisioning-key`."}

      assert [{:ssh, _status, nil}, {:ssh, _read, nil}] = calls()
    end

    test "refuses a first start while the removal of the shared key or a person is not finished",
         %{
           opts: opts
         } do
      mock_server(
        keys:
          "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n" <>
            "# ehos-administrator-removed:shared #{line(@shared)}\n" <>
            "# ehos-administrator-removed:bob #{line(@bob)}\n"
      )

      assert ClientCa.rotate(opts) ==
               {:error,
                "ehos-trial has not finished the removal of shared, bob, and GCP's guest agent " <>
                  "can put their key back, so ehosctl did not start the rotation. Run " <>
                  "`mix ehos.server admin remove shared`, `mix ehos.server admin remove bob` " <>
                  "until each finishes, then run the command again."}

      assert [{:ssh, _status, nil}, {:ssh, _read, nil}] = calls()
    end

    test "gives the start the last run it read, and starts nothing when another began since", %{
      opts: opts
    } do
      mock_server(
        status:
          status_output(
            "active",
            "inactive",
            "none",
            [deployment("ehos-governance"), deployment("ehos-operator")],
            "00000000000000aa"
          ),
        start: 11
      )

      assert ClientCa.rotate(opts) ==
               {:error,
                "Another ehosctl ran a rotation of the client CA on ehos-trial after this one read " <>
                  "the server, so ehosctl did not start one more. Run " <>
                  "`mix ehos.server admin list` to see the state of the server, then run the " <>
                  "command again if you still need a rotation."}

      assert [_status, _read, {:sh, start, started}] = calls()
      assert [_run, "start", "00000000000000aa", _script] = String.split(started, "\n", parts: 4)
      assert start =~ ~S|if [ "$mode" = start ] && [ "${l:--}" != "$last" ]; then exit 11; fi|
    end

    test "refuses a first start while no installation administrator has access of their own", %{
      opts: opts
    } do
      mock_server(keys: "#{line(@shared)} operator\n")

      assert ClientCa.rotate(opts) ==
               {:error,
                "ehos-trial has no installation administrator of their own, so ehosctl did not " <>
                  "start the rotation. Add each person with " <>
                  "`mix ehos.server admin add NAME --public-key FILE`, remove the shared key " <>
                  "with `mix ehos.server admin remove shared`, then run the command again."}
    end

    test "starts again, with no check of the administrators, when a rotation began", %{
      opts: opts
    } do
      mock_server(
        status: status_output("inactive", "inactive", "complete", :unread),
        keys: "#{line(@shared)} operator\n",
        polls: [fn run -> poll("inactive", "#{run} finished -", "run #{run}\n") end]
      )

      assert {:ok, %Report{}} = ClientCa.rotate(opts)

      assert [{:ssh, _status, nil}, {:sh, _start, started}, {:sh, _follow_log, "0\n" <> _run}] =
               calls()

      assert [_run, "again", "-", _script] = String.split(started, "\n", parts: 4)
    end

    test "follows the process that runs, with the id of its run from the log", %{opts: opts} do
      mock_server(
        status: status_output("active", "active", "complete", []),
        polls: [
          fn _run -> poll("active", "-", "run 00000000000000aa\nstep check\n") end,
          fn _run -> poll("inactive", "00000000000000aa finished -", "") end
        ]
      )

      assert {:ok, %Report{}} = ClientCa.rotate(opts)
      # The first read asks for the run that `current` names; the next, for that run.
      assert [
               {:ssh, _status, nil},
               {:sh, follow, "0\n-\n"},
               {:sh, follow, "32\n00000000000000aa\n"}
             ] =
               calls()

      assert progress() == [
               "Following the rotation that runs on ehos-trial",
               "Checking the new admin certificate, the old one and the node"
             ]
    end

    test "follows the run that the start found running, as it printed it under its lock", %{
      opts: opts
    } do
      mock_server(
        start: {"sudo: unable to resolve host ehos-trial\n00000000000000cc\n", 10},
        polls: [
          fn _run -> poll("inactive", "00000000000000cc finished -", "run 00000000000000cc\n") end
        ]
      )

      assert {:ok, %Report{}} = ClientCa.rotate(opts)

      assert [_status, _read, {:sh, _start, _input}, {:sh, _follow, "0\n00000000000000cc\n"}] =
               calls()
    end

    test "follows the run that the server named when ehosctl read it", %{opts: opts} do
      mock_server(
        status: status_output("active", "active", "complete", [], "00000000000000aa"),
        polls: [
          fn _run -> poll("inactive", "00000000000000aa finished -", "run 00000000000000aa\n") end
        ]
      )

      assert {:ok, %Report{}} = ClientCa.rotate(opts)
      assert [{:ssh, _status, nil}, {:sh, _follow, "0\n00000000000000aa\n"}] = calls()
    end

    test "follows the process that another ehosctl started meanwhile", %{opts: opts} do
      mock_server(
        start: 10,
        polls: [
          fn _run -> poll("inactive", "00000000000000bb finished -", "run 00000000000000bb\n") end
        ]
      )

      assert {:ok, %Report{}} = ClientCa.rotate(opts)

      assert progress() == [
               "Starting the rotation of the client CA on ehos-trial",
               "Following the rotation that runs on ehos-trial"
             ]
    end

    test "says that the rotation was undone, with what the failed step printed", %{opts: opts} do
      mock_server(
        polls: [
          fn run ->
            poll(
              "inactive",
              "#{run} undone rotate-ca",
              "run #{run}\nstep rotate-ca\noutput WARN[0000] file not found\n" <>
                "step put-back\nstep check-old\noutput node Ready\nstep scale-up\n" <>
                "output deployment.apps/ehos-governance scaled\nstep delete-copy\n" <>
                "step unannotate\noutput deployment.apps/ehos-governance annotated\n"
            )
          end
        ]
      )

      assert ClientCa.rotate(opts) ==
               {:error,
                Failure.new(
                  "ehosctl undid the rotation of the client CA on ehos-trial, because a step " <>
                    "failed, at the step \"Replacing the client CA with `k3s certificate " <>
                    "rotate-ca`\". It put back the copy of k3s from before the rotation, so the " <>
                    "cluster trusts the old client CA again, and the shared admin certificate " <>
                    "of k3s works again. What a controller or a person changed in the cluster " <>
                    "during the rotation is lost. Run the command again.",
                  "the rotation on the server",
                  "WARN[0000] file not found"
                )}
    end

    test "says where the copy is when the cluster did not come back", %{opts: opts} do
      mock_server(
        polls: [fn run -> poll("inactive", "#{run} kept check-old", "run #{run}\n") end]
      )

      assert ClientCa.rotate(opts) ==
               {:error,
                "ehosctl could not undo the rotation of the client CA on ehos-trial with its copy " <>
                  "of k3s from before the rotation, at the step \"Checking the old admin " <>
                  "certificate and the node\". The copy stays in /var/lib/ehosctl/client-ca/copy " <>
                  "on the server, and EHOS stays at zero replicas. Over SSH, `sudo systemctl " <>
                  "status k3s` and `sudo journalctl -u k3s` show why k3s does not start. Repair " <>
                  "it, then run the command again."}
    end

    test "says when it undid a rotation that a process before left", %{opts: opts} do
      mock_server(polls: [fn run -> poll("inactive", "#{run} undone -", "run #{run}\n") end])

      assert {:error, said} = ClientCa.rotate(opts)

      assert said =~
               "ehosctl undid the rotation of the client CA on ehos-trial, because a rotation " <>
                 "before stopped before its checks passed. It put back the copy"
    end

    test "says when it ended a rotation that had stopped", %{
      opts: opts
    } do
      mock_server(polls: [fn run -> poll("inactive", "#{run} reverted -", "run #{run}\n") end])

      assert ClientCa.rotate(opts) ==
               {:error,
                "ehosctl ended a rotation of the client CA on ehos-trial that had stopped. The " <>
                  "cluster trusts the client CA from before the rotation, and EHOS runs again. " <>
                  "Run the command again to rotate the client CA."}
    end

    test "says the token stayed when a rotation stopped between the two and its copy is gone",
         %{opts: opts} do
      mock_server(polls: [fn run -> poll("inactive", "#{run} partial -", "run #{run}\n") end])

      assert ClientCa.rotate(opts) ==
               {:error,
                "ehos-trial has a new client CA, but its server token is the one from before the " <>
                  "rotation: a rotation stopped between the two, and its copy of k3s is gone, so " <>
                  "ehosctl did not replace the token. EHOS runs again. Run the command again to " <>
                  "replace both."}
    end

    test "says what can be left when it finished the cleanup of a rotation that did not pass",
         %{opts: opts} do
      mock_server(polls: [fn run -> poll("inactive", "#{run} ended -", "run #{run}\n") end])

      assert ClientCa.rotate(opts) ==
               {:error,
                "ehosctl finished the cleanup of a rotation of the client CA on ehos-trial that " <>
                  "stopped before its checks passed. The client CA, the server token of k3s, or " <>
                  "both, can be the ones from before the rotation. EHOS runs again. Run the " <>
                  "command again to replace both."}
    end

    test "says to run it again when it could not finish the cleanup of a rotation that did not pass",
         %{opts: opts} do
      mock_server(
        polls: [fn run -> poll("inactive", "#{run} unclosed unannotate", "run #{run}\n") end]
      )

      assert ClientCa.rotate(opts) ==
               {:error,
                "ehosctl could not finish the cleanup, at the step \"Removing the annotations " <>
                  "of the rotation\". It cleans up after a rotation of the client CA on " <>
                  "ehos-trial that stopped before its checks passed. The client CA, the server " <>
                  "token of k3s, or both, can be the ones from before the rotation. Run the " <>
                  "command again to finish the cleanup."}
    end

    test "says k3s does not start, and that the client CA did not change", %{opts: opts} do
      mock_server(
        polls: [fn run -> poll("inactive", "#{run} down start-k3s", "run #{run}\n") end]
      )

      assert ClientCa.rotate(opts) ==
               {:error,
                "k3s does not start on ehos-trial after a step of the rotation of the client CA " <>
                  "failed, at the step \"Starting k3s\". The client CA did not change, and EHOS " <>
                  "stays at zero replicas. Repair k3s over SSH, as `sudo systemctl status k3s` " <>
                  "shows, then run the command again."}
    end

    test "says k3s does not start after the checks passed, and that it does not undo", %{
      opts: opts
    } do
      mock_server(
        polls: [fn run -> poll("inactive", "#{run} stalled start-k3s", "run #{run}\n") end]
      )

      assert ClientCa.rotate(opts) ==
               {:error,
                "k3s does not start on ehos-trial, at the step \"Starting k3s\". The rotation of " <>
                  "the client CA passed its checks, so ehosctl does not undo it, and EHOS stays at " <>
                  "zero replicas. Repair k3s over SSH, as `sudo systemctl status k3s` shows, then " <>
                  "run the command again to finish the rotation."}
    end

    test "says an undo did not finish", %{opts: opts} do
      mock_server(
        polls: [fn run -> poll("inactive", "#{run} unclean scale-up", "run #{run}\n") end]
      )

      assert ClientCa.rotate(opts) ==
               {:error,
                "ehosctl undid the rotation of the client CA on ehos-trial, but could not finish " <>
                  "the undo, at the step \"Scaling EHOS back to its replica counts\". The " <>
                  "cluster trusts the client CA from before the rotation. EHOS can stay at zero " <>
                  "replicas, and the copy of k3s can stay on the disk. Run the command again."}
    end

    test "says when it found no rotation to finish", %{opts: opts} do
      mock_server(polls: [fn run -> poll("inactive", "#{run} cleared -", "run #{run}\n") end])

      assert ClientCa.rotate(opts) ==
               {:error,
                "ehosctl found no rotation of the client CA to finish on ehos-trial. It started " <>
                  "k3s if it was stopped. Run the command again to start the rotation."}
    end

    test "says to run it again when the process stopped without a result", %{opts: opts} do
      mock_server(polls: [fn run -> poll("inactive", "-", "run #{run}\nstep copy\n") end])

      assert ClientCa.rotate(opts) ==
               {:error,
                "The rotation of the client CA on ehos-trial stopped before it ended, at the " <>
                  "step \"Copying /var/lib/rancher/k3s/server aside\". Run the command again: " <>
                  "it finishes the rotation or undoes it."}
    end

    test "takes no result of an earlier run for its own", %{opts: opts} do
      mock_server(
        polls: [fn run -> poll("inactive", "00000000000000cc finished -", "run #{run}\n") end]
      )

      assert ClientCa.rotate(opts) ==
               {:error,
                "The rotation of the client CA on ehos-trial stopped before it ended. Run the " <>
                  "command again: it finishes the rotation or undoes it."}
    end

    test "stops following after 10 reads in a row that fail, and says the rotation goes on", %{
      opts: opts
    } do
      mock_server(polls: [fn _run -> {"Connection timed out", 255} end])

      assert ClientCa.rotate(opts) ==
               {:error,
                Failure.new(
                  "ehosctl could not read the rotation on ehos-trial 10 times in a row. The " <>
                    "rotation goes on on the server. Run the command again to follow it.",
                  "ssh",
                  "Connection timed out"
                )}

      assert length(calls()) == 2 + 1 + 10
    end

    test "stops following after 45 minutes, and says the rotation still runs", %{opts: opts} do
      mock_server(
        polls: [
          fn run -> poll("active", "-", "run #{run}\n") end,
          fn _run ->
            Process.put(:now, DateTime.add(@began, 45, :minute))
            poll("active", "-", "")
          end
        ]
      )

      assert ClientCa.rotate(opts) ==
               {:error,
                "The rotation of the client CA still runs on ehos-trial after 45 minutes. Run " <>
                  "the command again to follow it."}
    end

    test "starts nothing, and follows nothing, while another ehosctl holds the start's lock to start or read",
         %{
           opts: opts
         } do
      mock_server(start: 12)

      assert ClientCa.rotate(opts) ==
               {:error,
                "Another ehosctl is starting a rotation of the client CA on ehos-trial, or " <>
                  "reading its state, at this moment, so ehosctl started none. Run the command " <>
                  "again in a moment: it follows a rotation that started, or starts one."}

      assert [_status, _read, {:sh, _start, _input}] = calls()
    end

    test "says why it could not start the process", %{opts: opts} do
      mock_server(start: {"Failed to start transient service unit", 5})

      assert ClientCa.rotate(opts) ==
               {:error,
                Failure.new(
                  "ehosctl could not start the rotation on ehos-trial (exit status 5).",
                  "ssh",
                  "Failed to start transient service unit"
                )}
    end
  end

  defp status do
    %{
      k3s?: true,
      process?: false,
      copy: :none,
      last: "-",
      deployments: [deployment("ehos-governance"), deployment("ehos-operator")]
    }
  end

  defp deployment(name, annotations \\ %{}),
    do: %{
      "kind" => "Deployment",
      "metadata" => %{"name" => name, "namespace" => "ehos-system", "annotations" => annotations}
    }

  defp line({type, blob}), do: "#{type} #{blob}"

  defp status_output(k3s, process, copy, deployments, last \\ "-") do
    printed =
      case deployments do
        :unread -> "--- unread ---\nThe connection to the server 127.0.0.1:6443 was refused\n"
        items -> Jason.encode!(%{"items" => items}) <> "\n"
      end

    {"k3s #{k3s}\nprocess #{process}\ncopy #{copy}\nlast #{last}\n--- ehosctl client CA ---\n" <>
       printed, 0}
  end

  defp admin_output(keys) do
    {"#{hash(keys)}\n#{Base.encode64(keys)}" <>
       @marker <>
       ~s({"items": []}) <> @marker <> ~s({"items": []}) <> @marker <> ~s({"items": []}) <> "\n",
     0}
  end

  defp hash(keys), do: Base.encode16(:crypto.hash(:sha256, keys), case: :lower)

  # What the follow script prints: the run, which ehosctl started or the server names, as `current`
  # does, from the run header of the log when ehosctl started none.
  defp current(run) do
    Process.put(:current, run)
    run
  end

  defp poll(process, result, log) do
    run =
      Process.get(:run) ||
        Process.get(:current) ||
        case Regex.run(~r/^run ([0-9a-f]+)$/m, log) do
          [_line, run] -> current(run)
          nil -> "-"
        end

    {"run #{run}\nprocess #{process}\nresult #{result}\n--- log ---\n" <> log, 0}
  end

  # The server: `status` answers the status script, by default k3s running with both Deployments
  # and nothing begun; `keys` is authorized_keys for the read of the administrators, by default ada
  # alone; `start` is the start script's exit status, or its output and status; `polls` answer the
  # reads of the log in turn, the last one again, each given the id of the run that ehosctl
  # started. Each call is recorded as `{:ssh, command, nil}` or `{:sh, command, input}`.
  defp mock_server(answers) do
    test = self()

    status =
      Keyword.get(
        answers,
        :status,
        status_output("active", "inactive", "none", [
          deployment("ehos-governance"),
          deployment("ehos-operator")
        ])
      )

    keys = Keyword.get(answers, :keys, "#{line(@ada)} ehos-administrator:ada:1a2b3c4d\n")
    polls = Keyword.get(answers, :polls, [])

    start =
      case Keyword.get(answers, :start, 0) do
        status when is_integer(status) -> {"", status}
        answer -> answer
      end

    stub(CommandRunnerMock, :run, fn
      "ssh", args ->
        command = List.last(args)
        send(test, {:ssh, command, nil})

        if command =~ "--- ehosctl client CA ---",
          do: status,
          else: admin_output(keys)

      "sh", ["-c", ~S(exec ssh "$@" <"$0"), input | args] ->
        command = List.last(args)
        input = File.read!(input)
        send(test, {:sh, command, input})

        if command =~ "systemd-run",
          do: started(input, start),
          else: polled(polls)
    end)
  end

  # The run started is the one followed only when the start said so.
  defp started(input, start) do
    run = input |> String.split("\n") |> hd()
    if match?({_output, 0}, start), do: Process.put(:run, run)
    start
  end

  defp polled(polls) do
    count = Process.get(:polls, 0)
    Process.put(:polls, count + 1)
    Enum.at(polls, count, List.last(polls)).(Process.get(:run))
  end

  defp calls do
    receive do
      {kind, command, detail} -> [{kind, command, detail} | calls()]
    after
      0 -> []
    end
  end

  defp progress do
    receive do
      {:progress, {:step, said}} -> [said | progress()]
      {:progress, _other} -> progress()
    after
      0 -> []
    end
  end
end
