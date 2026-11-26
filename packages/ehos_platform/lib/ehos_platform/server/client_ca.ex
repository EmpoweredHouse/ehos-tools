defmodule EhosPlatform.Server.ClientCa do
  @moduledoc """
  Ends the admin certificate of k3s that every administrator of an installation made before
  eh-os D-199 copied: it replaces the client CA of the cluster with a new one and then the server
  token of k3s, behind `ehosctl server rotate-client-ca`. It is step 3 of D-199's "Existing
  installations", once each administrator has access of their own and the shared key is gone.

  The rotation is one process on the server, which a systemd unit of its own,
  `ehosctl-client-ca`, runs as root, so that it goes on when SSH drops: each administrator's own
  certificate stops working at its second restart of k3s, and it reaches the cluster through
  `k3s kubectl` on the server alone. It records what it did in annotations on EHOS's Deployments
  and keeps a copy of `/var/lib/rancher/k3s/server` until its checks pass, so that it can undo a
  failure, and a run again finishes or undoes what a process that stopped began.

  `rotate/1` reads the server (`status/2`), decides from it whether to start the process, start it
  again, or follow the one that runs (`decide/2`), refuses a first start until the server is ready
  for it (`ready/3`), then follows the process's log, a line for each step, until it writes its
  result (`parse_log/1`), and reports that result.
  """

  alias EhosPlatform.Failure
  alias EhosPlatform.Report
  alias EhosPlatform.Server
  alias EhosPlatform.Server.Administrators

  @dir "/var/lib/ehosctl/client-ca"
  @namespace "ehos-system"
  @deployments ["ehos-governance", "ehos-operator"]
  @annotation "ehos.empowered.house/client-ca-rotation-"
  @marker "--- ehosctl client CA ---"
  @unread "--- unread ---"
  @log_marker "--- log ---"
  # How often ehosctl reads the process's log, how long it follows it, and how many reads in a row
  # may fail before it stops following: the process goes on without it.
  @poll 3_000
  @limit_minutes 45
  @lost_reads 10

  # What the server holds of the rotation: whether k3s and the process run, how much of the copy
  # there is, then EHOS's Deployments as kubectl prints them, or why it could not read them, as
  # while k3s is stopped. `systemctl is-active` prints `inactive` for a unit that does not exist.
  @status_script ~S"""
  d=/var/lib/ehosctl/client-ca
  sudo -n true || exit 4
  e=$(mktemp) || exit 3
  trap 'rm -f "$e"' EXIT
  printf 'k3s %s\n' "$(systemctl is-active k3s.service)"
  printf 'process %s\n' "$(systemctl is-active ehosctl-client-ca.service)"
  if sudo -n test -e "$d/copy.complete"; then echo 'copy complete'
  elif sudo -n test -e "$d/copy"; then echo 'copy partial'
  else echo 'copy none'; fi
  printf '%s\n' '--- ehosctl client CA ---'
  sudo -n k3s kubectl get --request-timeout=30s deployments ehos-governance ehos-operator --namespace ehos-system --ignore-not-found -o json 2>"$e" || { printf '%s\n' '--- unread ---'; cat "$e"; }
  """

  # Standard input: the id of the run, then the process's script. It starts the process under a
  # systemd unit of its own, which outlives the SSH session, unless that unit runs already: 10.
  # The log of the run before is kept beside the new one.
  @start_script ~S"""
  set -u
  d=/var/lib/ehosctl/client-ca
  IFS= read -r run
  case "$run" in ''|*[!0-9a-f]*) exit 2;; esac
  sudo -n true || exit 4
  if systemctl is-active --quiet ehosctl-client-ca.service; then exit 10; fi
  sudo -n install -d -m 700 /var/lib/ehosctl "$d" || exit 3
  if sudo -n test -e "$d/log"; then sudo -n mv -f "$d/log" "$d/log.previous" || exit 3; fi
  sudo -n rm -f "$d/result" || exit 3
  sudo -n tee "$d/process.sh" >/dev/null || exit 3
  sudo -n systemd-run --unit=ehosctl-client-ca --collect --quiet --property=Type=exec /bin/sh "$d/process.sh" "$run" || exit 5
  """

  # Standard input: how many bytes of the log ehosctl read already. It prints whether the process
  # runs, its result or `-`, then the rest of the log. The result is read before the log, and the
  # process writes it last, so a result comes with the whole log.
  @follow_script ~S"""
  d=/var/lib/ehosctl/client-ca
  IFS= read -r offset
  case "$offset" in ''|*[!0-9]*) exit 2;; esac
  sudo -n true || exit 4
  printf 'process %s\n' "$(systemctl is-active ehosctl-client-ca.service)"
  r=$(sudo -n cat "$d/result" 2>/dev/null) || r=-
  printf 'result %s\n' "${r:--}"
  printf '%s\n' '--- log ---'
  sudo -n tail -c "+$((offset + 1))" "$d/log" 2>/dev/null
  exit 0
  """

  # The process, run as root by its systemd unit with the id of its run. It writes each step to
  # the log as `step <name>`, a program's output as `output <line>`, and its result last, as
  # `<run> <outcome> <step>`, through a rename, so that a result is never read in part.
  @process_script ~S"""
  set -u
  d=/var/lib/ehosctl/client-ca
  run=$1
  log() { printf '%s\n' "$*" >>"$d/log"; }
  said() { while IFS= read -r l; do log "output $l"; done; }
  result() {
    printf '%s %s %s\n' "$run" "$1" "$2" >"$d/result.new" && mv -f "$d/result.new" "$d/result"
    exit 0
  }
  log "run $run"
  log "step space"
  need=$(du -sk /var/lib/rancher/k3s/server | cut -f1) || result failed space
  free=$(df -Pk "$d" | awk 'NR == 2 { print $4 }') || result failed space
  if [ "$free" -le $((need + 524288)) ]; then
    echo "The copy needs ${need} KiB and 512 MiB more. ${free} KiB are free." | said
    result failed space
  fi
  result failed unbuilt
  """

  @steps %{
    "space" => "Checking the room on the disk for a copy of k3s",
    "scale-down" => "Scaling the governance plane and the operator of EHOS to zero",
    "stop-k3s" => "Stopping k3s",
    "copy" => "Copying /var/lib/rancher/k3s/server aside",
    "start-k3s" => "Starting k3s",
    "new-ca" => "Making a new client CA on the server",
    "rotate-ca" => "Replacing the client CA with `k3s certificate rotate-ca`",
    "restart-k3s" => "Restarting k3s",
    "rotate-token" => "Replacing the server token with `k3s token rotate`",
    "check" => "Checking the new admin certificate, the old one and the node",
    "put-back" => "Putting the copy of k3s back",
    "check-old" => "Checking the old admin certificate and the node",
    "scale-up" => "Scaling EHOS back to its replica counts",
    "delete-copy" => "Deleting the copy of k3s",
    "unannotate" => "Removing the annotations of the rotation"
  }

  @typedoc """
  What `status/2` read of the server: whether k3s and the process run, how much of the copy there
  is, and EHOS's Deployments, or what kubectl printed when it could not read them.
  """
  @type status :: %{
          k3s?: boolean(),
          process?: boolean(),
          copy: :none | :partial | :complete,
          deployments: [map()] | {:unread, String.t()}
        }

  @typedoc """
  What to do: start the process on a server ready for it, start it again to finish or undo what a
  process before began, or follow the process that runs.
  """
  @type move :: :start | :again | :follow

  @typedoc """
  A line of the process's log, as `parse_log/1` reads it: the run it belongs to, a step it begins,
  a line a program printed, or a line in no form ehosctl knows, which it skips.
  """
  @type entry :: {:run, String.t()} | {:step, String.t()} | {:output, String.t()} | :other

  @typedoc "The process's result: its run, its outcome, and the step it ended at, or `nil`."
  @type result :: %{run: String.t(), outcome: String.t(), step: String.t() | nil}

  @doc """
  Replaces the client CA and the server token of k3s on the installation's server, or finishes or
  undoes a rotation that stopped, and follows the process on the server until it ends. `opts` are
  `EhosPlatform.Server.up/1`'s.
  """
  @spec rotate(keyword()) :: Server.result()
  def rotate(opts) do
    with {:ok, server, address} <- Server.connect(opts),
         {:ok, status} <- status(server, address),
         {:ok, move} <- decide(status, server.name),
         :ok <- allowed(move, server, address),
         {:ok, run} <- started(move, server, address),
         {:ok, result} <- follow(server, address, run) do
      reported(result, server)
    end
  end

  @doc """
  Reads what the server holds of the rotation, in one SSH command.
  """
  @spec status(Server.t(), String.t()) :: {:ok, status()} | {:error, Failure.message()}
  def status(server, address) do
    case Server.on_server(server, address, @status_script) do
      {output, 0} ->
        parse_status(output)

      result ->
        failed(result, "ehosctl could not read the client CA of ehos-#{server.name}.")
    end
  end

  @doc """
  The status the status script printed, or an error when it is not in that form.

      iex> EhosPlatform.Server.ClientCa.parse_status(
      ...>   "k3s active\\nprocess inactive\\ncopy none\\n--- ehosctl client CA ---\\n" <>
      ...>     ~s({"items": []}) <> "\\n"
      ...> )
      {:ok, %{k3s?: true, process?: false, copy: :none, deployments: []}}

      iex> EhosPlatform.Server.ClientCa.parse_status(
      ...>   "k3s inactive\\nprocess inactive\\ncopy complete\\n--- ehosctl client CA ---\\n" <>
      ...>     "--- unread ---\\nThe connection to the server 127.0.0.1:6443 was refused\\n"
      ...> )
      {:ok,
       %{
         k3s?: false,
         process?: false,
         copy: :complete,
         deployments: {:unread, "The connection to the server 127.0.0.1:6443 was refused\\n"}
       }}
  """
  @spec parse_status(String.t()) :: {:ok, status()} | {:error, String.t()}
  def parse_status(output) do
    with [head, deployments] <- String.split(output, @marker <> "\n", parts: 2),
         ["k3s " <> k3s, "process " <> process, "copy " <> copy] <-
           String.split(head, "\n", trim: true),
         {:ok, copy} <- copy(copy),
         {:ok, deployments} <- deployments(deployments) do
      {:ok,
       %{
         k3s?: k3s == "active",
         process?: process == "active",
         copy: copy,
         deployments: deployments
       }}
    else
      _other -> {:error, "The server answered in a form that ehosctl cannot read."}
    end
  end

  defp copy("none"), do: {:ok, :none}
  defp copy("partial"), do: {:ok, :partial}
  defp copy("complete"), do: {:ok, :complete}
  defp copy(_other), do: :error

  defp deployments(@unread <> "\n" <> printed), do: {:ok, {:unread, printed}}

  defp deployments(printed) do
    case String.trim(printed) do
      "" -> {:ok, []}
      json -> json |> Jason.decode() |> items()
    end
  end

  defp items({:ok, %{"items" => items}}) when is_list(items), do: {:ok, items}
  defp items({:ok, %{"kind" => "Deployment"} = deployment}), do: {:ok, [deployment]}
  defp items(_other), do: :error

  @doc """
  What to do on the server named `name` in `status` (eh-os D-199): follow the process that runs;
  start it again when a rotation began, as a copy, a k3s that is stopped or an annotation on a
  Deployment of EHOS shows; else start it, which needs both Deployments of EHOS, since the
  annotations on them are what a run again finishes or undoes from.
  """
  @spec decide(status(), String.t()) :: {:ok, move()} | {:error, Failure.message()}
  def decide(%{process?: true}, _name), do: {:ok, :follow}

  def decide(%{copy: copy, k3s?: k3s?} = status, name) do
    if copy != :none or not k3s? or annotated?(status.deployments),
      do: {:ok, :again},
      else: startable(status.deployments, name)
  end

  defp annotated?({:unread, _printed}), do: false

  defp annotated?(deployments) do
    for deployment <- deployments,
        key <- Map.keys(annotations(deployment)),
        reduce: false,
        do: (found -> found or String.starts_with?(key, @annotation))
  end

  defp annotations(deployment), do: get_in(deployment, ["metadata", "annotations"]) || %{}

  defp startable({:unread, printed}, name),
    do:
      {:error,
       Failure.printed(
         "ehosctl could not read the Deployments of EHOS on ehos-#{name}, so it did not start " <>
           "the rotation. Make sure that k3s runs, then run the command again.",
         "kubectl",
         printed
       )}

  defp startable(deployments, name) do
    found = for %{"metadata" => %{"name" => found}} <- deployments, do: found

    case @deployments -- found do
      [] ->
        {:ok, :start}

      missing ->
        {:error,
         "ehos-#{name} has no Deployment #{Enum.join(missing, " or ")} in #{@namespace}, so " <>
           "ehosctl did not start the rotation: it records the rotation on the Deployments of " <>
           "EHOS. Install EHOS with `install`, then run the command again."}
    end
  end

  @doc """
  Whether the server in `state`, with the `provisioning` key, is ready for a first rotation
  (eh-os D-199): an installation administrator has access of their own, and the key that every
  administrator shared is gone. Until then a rotation would end only the admin certificate that a
  person can copy again with the shared key.
  """
  @spec ready(Administrators.state(), term(), Server.t()) :: :ok | {:error, String.t()}
  def ready(state, provisioning, server) do
    cond do
      Administrators.persons(state) == [] ->
        {:error,
         "ehos-#{server.name} has no installation administrator of their own, so ehosctl did " <>
           "not start the rotation. Add each person with " <>
           "`#{command(server, "admin add NAME --public-key FILE")}`, remove the shared key " <>
           "with `#{command(server, "admin remove shared")}`, then run the command again."}

      Administrators.shared_kept?(state, provisioning) ->
        {:error,
         "ehos-#{server.name} still has the key that every installation administrator shared, " <>
           "so ehosctl did not start the rotation. With that key, a person can copy the admin " <>
           "certificate of k3s again. Remove it with " <>
           "`#{command(server, "admin remove shared")}`, then run the command again. On GCP, " <>
           "first give the key of an installation administrator to `up --provisioning-key`."}

      true ->
        :ok
    end
  end

  defp allowed(:start, server, address) do
    with {:ok, state} <- Administrators.read(server, address),
         do: ready(state, Administrators.provisioning(server), server)
  end

  defp allowed(_again_or_follow, _server, _address), do: :ok

  defp started(:follow, server, _address) do
    server.progress.({:step, "Following the rotation that runs on ehos-#{server.name}"})
    {:ok, nil}
  end

  defp started(_start_or_again, server, address) do
    run = 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    server.progress.({:step, "Starting the rotation of the client CA on ehos-#{server.name}"})

    case Server.on_server(server, address, @start_script, input: run <> "\n" <> @process_script) do
      {_output, 0} -> {:ok, run}
      {_output, 10} -> started(:follow, server, address)
      result -> failed(result, "ehosctl could not start the rotation on ehos-#{server.name}.")
    end
  end

  # `run` is the id of the run that ehosctl started, or `nil` when it follows one that ran
  # already, whose id the first line of the log gives.
  defp follow(server, address, run) do
    poll(%{
      server: server,
      address: address,
      run: run,
      offset: 0,
      step: nil,
      output: [],
      lost: 0,
      began: server.clock.utc_now()
    })
  end

  defp poll(follow) do
    follow.server.clock.sleep(@poll)

    follow.server
    |> Server.on_server(follow.address, @follow_script, input: "#{follow.offset}\n")
    |> polled(follow)
  end

  defp polled({output, 0}, follow) do
    case String.split(output, "\n" <> @log_marker <> "\n", parts: 2) do
      [head, log] -> head |> String.split("\n") |> read_poll(log, follow)
      _other -> lost(follow, output)
    end
  end

  defp polled({:error, :not_found}, _follow),
    do: {:error, "`ssh` is not installed. `ehosctl doctor` says what is missing"}

  defp polled({output, _status}, follow), do: lost(follow, output)

  defp read_poll(["process " <> process, "result " <> result], log, follow) do
    follow = logged(follow, log)

    case {parse_result(result), follow.run} do
      {%{run: run} = result, run} -> {:ok, Map.put(result, :output, Enum.reverse(follow.output))}
      _none when process == "active" -> next(follow)
      _none -> {:error, stopped(follow)}
    end
  end

  defp read_poll(_other, _log, follow), do: lost(follow, "")

  # Only whole lines: the process can be in the middle of one.
  defp logged(follow, log) do
    whole = log |> String.split("\n") |> Enum.drop(-1)
    read = Enum.reduce(whole, 0, &(&2 + byte_size(&1) + 1))

    whole
    |> Enum.map(&parse_log/1)
    |> Enum.reduce(%{follow | offset: follow.offset + read, lost: 0}, &entered/2)
  end

  defp entered({:run, run}, %{run: nil} = follow), do: %{follow | run: run}
  defp entered({:run, _run}, follow), do: follow

  defp entered({:step, step}, follow) do
    follow.server.progress.({:step, step_said(step)})
    %{follow | step: step, output: []}
  end

  defp entered({:output, line}, follow), do: %{follow | output: [line | follow.output]}
  defp entered(:other, follow), do: follow

  @doc """
  A line of the process's log.

      iex> EhosPlatform.Server.ClientCa.parse_log("step rotate-ca")
      {:step, "rotate-ca"}

      iex> EhosPlatform.Server.ClientCa.parse_log("output WARN[0000] file not found")
      {:output, "WARN[0000] file not found"}
  """
  @spec parse_log(String.t()) :: entry()
  def parse_log("run " <> run), do: {:run, run}
  def parse_log("step " <> step), do: {:step, step}
  def parse_log("output " <> line), do: {:output, line}
  def parse_log(_other), do: :other

  @doc """
  The process's result, as its result file holds it, or `nil` for none.

      iex> EhosPlatform.Server.ClientCa.parse_result("0123456789abcdef undone rotate-ca")
      %{run: "0123456789abcdef", outcome: "undone", step: "rotate-ca"}

      iex> EhosPlatform.Server.ClientCa.parse_result("0123456789abcdef finished -")
      %{run: "0123456789abcdef", outcome: "finished", step: nil}

      iex> EhosPlatform.Server.ClientCa.parse_result("-")
      nil
  """
  @spec parse_result(String.t()) :: result() | nil
  def parse_result(line) do
    case String.split(line, " ") do
      [run, outcome, "-"] -> %{run: run, outcome: outcome, step: nil}
      [run, outcome, step] -> %{run: run, outcome: outcome, step: step}
      _none -> nil
    end
  end

  defp next(follow) do
    if over?(follow), do: {:error, still_runs(follow.server)}, else: poll(follow)
  end

  defp over?(follow),
    do: DateTime.diff(follow.server.clock.utc_now(), follow.began, :minute) >= @limit_minutes

  defp lost(%{lost: lost} = follow, output) when lost + 1 >= @lost_reads,
    do:
      {:error,
       Failure.printed(
         "ehosctl could not read the rotation on ehos-#{follow.server.name} #{@lost_reads} " <>
           "times in a row. The rotation goes on on the server. Run the command again to " <>
           "follow it.",
         "ssh",
         output
       )}

  defp lost(follow, _output) do
    follow = %{follow | lost: follow.lost + 1}
    if over?(follow), do: {:error, still_runs(follow.server)}, else: poll(follow)
  end

  defp still_runs(server),
    do:
      "The rotation of the client CA still runs on ehos-#{server.name} after " <>
        "#{@limit_minutes} minutes. Run the command again to follow it."

  defp stopped(follow),
    do:
      "The rotation of the client CA on ehos-#{follow.server.name} stopped before it ended" <>
        at(follow.step) <>
        ". Run the command again: it finishes the rotation or undoes it."

  defp at(nil), do: ""
  defp at(step), do: ", at the step \"#{step_said(step)}\""

  defp step_said(step), do: Map.get(@steps, step, "Step #{step} on the server")

  defp reported(%{outcome: "finished"}, server) do
    {:ok,
     %Report{
       outcome:
         "ehos-#{server.name} has a new client CA. The certificates of the old client CA no " <>
           "longer work.",
       values: [
         {"Ended", "the admin certificate of k3s that `tunnel` copied before"},
         {"Ended", "the certificate of each installation administrator"},
         {"Replaced", "the server token of k3s"}
       ],
       next: [command(server, "tunnel")],
       warnings: [
         {"Each installation administrator runs `tunnel` again.",
          "Their certificate was from the old client CA. `tunnel` issues a new one."},
         {"The rotation does not end each other way in.",
          "It keeps the server CA, the request-header CA and the key of the service accounts. " <>
            "A ServiceAccount token, a binding or a workload that someone made still works. " <>
            "`admin list` shows each binding to cluster-admin."}
       ]
     }}
  end

  defp reported(result, server), do: {:error, result_failure(result, server)}

  defp result_failure(%{outcome: "undone"} = result, server),
    do:
      printed(
        "ehosctl undid the rotation of the client CA on ehos-#{server.name}, because a step " <>
          "failed#{at(result.step)}. It put back the copy of k3s from before the rotation, so " <>
          "the cluster trusts the old client CA again, and the shared admin certificate of k3s " <>
          "works again. What a controller or a person changed in the cluster during the " <>
          "rotation is lost. Run the command again.",
        result
      )

  defp result_failure(%{outcome: "stopped"} = result, server),
    do:
      printed(
        "ehosctl stopped the rotation of the client CA on ehos-#{server.name}, because a step " <>
          "failed#{at(result.step)}. The client CA did not change, and EHOS runs again. Run the " <>
          "command again.",
        result
      )

  defp result_failure(%{outcome: "kept"} = result, server),
    do:
      printed(
        "The cluster on ehos-#{server.name} did not come back after ehosctl put back the copy " <>
          "of k3s from before the rotation#{at(result.step)}. The copy stays in #{@dir}/copy on " <>
          "the server, and EHOS stays at zero replicas. Repair k3s over SSH with " <>
          "`sudo k3s kubectl`, then run the command again.",
        result
      )

  defp result_failure(%{outcome: "unfinished"} = result, server),
    do:
      printed(
        "ehos-#{server.name} has a new client CA, but ehosctl could not finish the rotation" <>
          "#{at(result.step)}. EHOS can stay at zero replicas, and the copy of k3s can stay on " <>
          "the disk. Run the command again to finish it.",
        result
      )

  defp result_failure(%{outcome: "refused"} = result, server),
    do:
      printed(
        "A replica count in the annotations of EHOS on ehos-#{server.name} is not a whole " <>
          "number from 0 to 10, so ehosctl did not scale EHOS back. Correct the annotation " <>
          "#{@annotation}replicas on the Deployments #{Enum.join(@deployments, " and ")} in " <>
          "#{@namespace}, then run the command again.",
        result
      )

  defp result_failure(result, server),
    do:
      printed(
        "The rotation of the client CA on ehos-#{server.name} failed#{at(result.step)}. Run " <>
          "`#{command(server, "admin list")}` to see the state of the server.",
        result
      )

  defp printed(said, %{output: output}),
    do: Failure.printed(said, "the rotation on the server", Enum.join(output, "\n"))

  defp failed({:error, :not_found}, _said),
    do: {:error, "`ssh` is not installed. `ehosctl doctor` says what is missing"}

  defp failed({output, status}, said),
    do:
      {:error,
       Failure.printed(
         String.trim_trailing(said, ".") <> " (exit status #{status}).",
         "ssh",
         output
       )}

  defp command(server, args) do
    named = if server.name_in_commands, do: " #{server.name_option} #{server.name}", else: ""
    "#{server.command} #{args}#{named}"
  end
end
