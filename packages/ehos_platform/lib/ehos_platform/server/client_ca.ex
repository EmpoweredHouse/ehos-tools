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
  @poll 5_000
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
  elif sudo -n test -e "$d/copy" || sudo -n test -e "$d/ca"; then echo 'copy partial'
  else echo 'copy none'; fi
  printf '%s\n' '--- ehosctl client CA ---'
  sudo -n k3s kubectl get --request-timeout=30s deployments ehos-governance ehos-operator --namespace ehos-system --ignore-not-found -o json 2>"$e" || { printf '%s\n' '--- unread ---'; cat "$e"; }
  """

  # Standard input: the id of the run, `start` or `again`, then the process's script, which goes in
  # a file of its own run. A lock holds a start at the same moment off until the unit runs, which
  # it then finds (10): it never moves the log of the run that starts, or writes over its script. It starts the process under a
  # systemd unit of its own, which outlives the SSH session, unless that unit runs already: 10.
  # The log of the run before is kept beside the new one.
  @start_script ~S"""
  set -u
  d=/var/lib/ehosctl/client-ca
  IFS= read -r run
  IFS= read -r mode
  case "$run" in ''|*[!0-9a-f]*) exit 2;; esac
  case "$mode" in start|again) ;; *) exit 2;; esac
  sudo -n true || exit 4
  sudo -n install -d -m 700 /var/lib/ehosctl "$d" || exit 3
  sudo -n flock -n -E 10 "$d/start.lock" sh -c '
    set -u
    d=$1 run=$2 mode=$3
    if systemctl is-active --quiet ehosctl-client-ca.service; then exit 10; fi
    if [ -e "$d/log" ]; then mv -f "$d/log" "$d/log.previous" || exit 3; fi
    rm -f "$d/result" || exit 3
    tee "$d/process-$run.new" >/dev/null && mv -f "$d/process-$run.new" "$d/process-$run.sh" || exit 3
    systemd-run --unit=ehosctl-client-ca --collect --quiet --property=Type=exec /bin/sh "$d/process-$run.sh" "$run" "$mode" "$d" /var/lib/rancher/k3s/server || exit 5
  ' sh "$d" "$run" "$mode"
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

  # The process, run as root by its systemd unit with the id of its run, `start` or `again`, its
  # folder and k3s's server folder (eh-os D-199, "Existing installations", step 3). It writes each
  # step to the log as `step <name>`, a program's output as `output <line>`, and its result last,
  # as `<run> <outcome> <step>`, through a rename, so that a result is never read in part. It
  # decides from what the server holds, since k3s may be stopped when ehosctl reads it: with no
  # annotation, it rotates when it was started, and else ends (`cleared`); with annotations, it
  # finishes a rotation whose client CA on the disk is no longer the recorded one, rotating the
  # token first unless that is recorded, and undoes one whose CA is still the recorded one.
  @process_script ~S"""
  set -u
  run=$1
  mode=$2
  d=$3
  s=$4
  ns=ehos-system
  deployments="ehos-governance ehos-operator"
  a=ehos.empowered.house/client-ca-rotation-
  # The same, as the start of a line that `kubectl annotate --list` prints: a value of another
  # annotation can hold the name of one of these.
  ar='^ehos\.empowered\.house/client-ca-rotation-'
  step=-
  log() { printf '%s\n' "$*" >>"$d/log"; }
  said() { while IFS= read -r l; do log "output $l"; done; }
  begin() { step=$1; log "step $1"; }
  result() {
    printf '%s %s %s\n' "$run" "$1" "$2" >"$d/result.new" && mv -f "$d/result.new" "$d/result"
    exit 0
  }
  x() {
    o=$("$@" 2>&1)
    r=$?
    if [ -n "$o" ]; then printf '%s\n' "$o" | said; fi
    return "$r"
  }
  kc() { k3s kubectl --request-timeout=30s "$@"; }
  # The SHA-256 fingerprint of the certificate in `$1`; fails when it cannot be read.
  fp() {
    f=$(openssl x509 -in "$1" -noout -fingerprint -sha256) || return 1
    f=$(printf '%s\n' "${f#*=}" | tr -d :)
    [ -n "$f" ] && printf '%s\n' "$f"
  }

  # The value of the annotation `$a$2` on the Deployment `$1`, or nothing when it has none. It fails
  # when kubectl does: with no pipefail in sh, a pipeline would read a failure as no annotation.
  annotation() {
    l=$(kc annotate deployment "$1" --namespace "$ns" --list 2>&1) || { printf '%s\n' "$l" | said; return 1; }
    printf '%s\n' "$l" | grep "$ar$2=" | head -n 1 | cut -d= -f2-
  }
  up_k3s() { kc get --raw /readyz >/dev/null 2>&1; }

  wait_api() {
    i=0
    until up_k3s; do
      i=$((i + 1))
      if [ "$i" -gt 60 ]; then echo "The API server did not answer within 5 minutes." | said; return 1; fi
      sleep 5
    done
  }

  ready() {
    i=0
    while :; do
      n=$(kc get nodes -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null)
      if [ -n "$n" ] && ! printf '%s\n' "$n" | grep -qv '^True$'; then return 0; fi
      i=$((i + 1))
      if [ "$i" -gt 60 ]; then echo "The node is not Ready after 5 minutes." | said; return 1; fi
      sleep 5
    done
  }

  # What the API server answers a client certificate: 200 when it accepts it, 401 when it refuses it.
  answered() {
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert "$s/tls/server-ca.crt" \
      --cert "$1/tls/client-admin.crt" --key "$1/tls/client-admin.key" https://127.0.0.1:6443/api
  }

  # k3s's unit waits for its API server with no time limit (TimeoutStartSec=0), so a k3s whose API
  # never answers, as after a bad CA, would hold systemctl, and the undo, for ever: each call to
  # systemctl has 5 minutes. A later stop or start replaces the job left behind.
  unit() {
    x timeout 300 systemctl "$1" k3s.service
    r=$?
    if [ "$r" -eq 124 ]; then echo "systemctl $1 k3s.service did not end within 5 minutes." | said; fi
    return "$r"
  }

  start_k3s() {
    if ! systemctl is-active --quiet k3s.service; then
      begin start-k3s
      unit start || return 1
    fi
    wait_api
  }

  restart_k3s() {
    begin restart-k3s
    unit restart && wait_api
  }

  # A put back that stopped: the folder put back is whole once it is in place of the server's.
  repair() {
    if [ ! -e "$s" ] && [ -e "$s.ehosctl-new" ]; then mv "$s.ehosctl-new" "$s" || return 1; fi
    rm -rf "$s.ehosctl-new" "$s.ehosctl-old"
  }

  space() {
    begin space
    need=$(du -sk "$s" | cut -f1) || return 1
    free=$(df -Pk "$d" | awk 'NR == 2 { print $4 }') || return 1
    if [ "$free" -le $((2 * need + 524288)) ]; then
      echo "The copy and its put back need $((2 * need)) KiB and 512 MiB more. $free KiB are free." | said
      return 1
    fi
  }

  scale_down() {
    begin scale-down
    ca=$(fp "$s/tls/client-ca.crt") || return 1
    for dep in $deployments; do
      n=$(kc get deployment "$dep" --namespace "$ns" -o 'jsonpath={.spec.replicas}' 2>&1) || { printf '%s\n' "$n" | said; return 1; }
      if ! counted "$n"; then echo "The Deployment $dep has $n replicas. The rotation records 0 to 10." | said; return 1; fi
    done
    for dep in $deployments; do
      n=$(kc get deployment "$dep" --namespace "$ns" -o 'jsonpath={.spec.replicas}') || return 1
      x kc annotate deployment "$dep" --namespace "$ns" --overwrite "${a}replicas=$n" "${a}client-ca=$ca" || return 1
    done
    for dep in $deployments; do x kc scale deployment "$dep" --namespace "$ns" --replicas=0 || return 1; done
    i=0
    for dep in $deployments; do
      selector=$(kc get deployment "$dep" --namespace "$ns" -o 'go-template={{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}') || return 1
      while :; do
        p=$(kc get pods --namespace "$ns" --selector "${selector%,}" -o name) || return 1
        if [ -z "$p" ]; then break; fi
        i=$((i + 1))
        if [ "$i" -gt 60 ]; then echo "A pod of $dep is still there after 5 minutes." | said; return 1; fi
        sleep 5
      done
    done
  }

  counted() {
    case "$1" in '' | *[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 2 ] && [ "$1" -le 10 ]
  }

  copy() {
    begin stop-k3s
    unit stop || return 1
    begin copy
    x cp -a "$s" "$d/copy" && sync && : >"$d/copy.complete" && sync || return 1
    start_k3s
  }

  new_ca() {
    begin new-ca
    c="$d/ca"
    rm -rf "$c" && mkdir -p "$c/tls/etcd" && chmod 700 "$c" || return 1
    for f in server-ca.crt server-ca.key request-header-ca.crt request-header-ca.key service.key \
      etcd/peer-ca.crt etcd/peer-ca.key etcd/server-ca.crt etcd/server-ca.key; do
      if [ ! -s "$s/tls/$f" ]; then echo "$s/tls/$f is missing." | said; return 1; fi
      cp -p "$s/tls/$f" "$c/tls/$f" || return 1
    done
    x openssl ecparam -name prime256v1 -genkey -noout -out "$c/tls/client-ca.key" || return 1
    x openssl req -x509 -new -key "$c/tls/client-ca.key" -sha256 -days 3650 \
      -subj "/CN=k3s-client-ca@$(date +%s)" -addext 'basicConstraints=critical,CA:TRUE' \
      -addext 'keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign' \
      -out "$c/tls/client-ca.crt" || return 1
    for f in client-ca.crt client-ca.key server-ca.crt server-ca.key request-header-ca.crt \
      request-header-ca.key service.key etcd/peer-ca.crt etcd/server-ca.crt; do
      if [ ! -s "$c/tls/$f" ]; then echo "$c/tls/$f is missing." | said; return 1; fi
    done
  }

  # k3s's rotate-ca and token rotate warn, and exit 0, on what they could not do: a warning fails.
  clean() {
    o=$("$@" 2>&1)
    r=$?
    if [ -n "$o" ]; then printf '%s\n' "$o" | said; fi
    [ "$r" -eq 0 ] && ! printf '%s\n' "$o" | grep -Eqi 'warn|erro|fata|level=(warning|error|fatal)'
  }

  rotate_ca() {
    begin rotate-ca
    clean k3s certificate rotate-ca --path "$d/ca" --force || return 1
    restart_k3s || return 1
    now=$(fp "$s/tls/client-ca.crt") || return 1
    if [ "$now" = "$recorded" ]; then
      echo "The client CA on the disk is still the old one after the restart." | said
      return 1
    fi
    mark ca-rotated
  }

  # Reads the output of `token rotate`: it holds when k3s says the token rotated and no other line
  # warns. k3s always warns to keep a record of the old token, which is no failure. The log keeps no
  # line that holds a token, and the tokens are matched with the shell alone, so that neither is on
  # the command line of a program, which any user on the host can read.
  rotated() {
    said_rotated=1
    warned=
    while IFS= read -r l; do
      case "$l" in
        '' | *'Recommended to keep a record of the old token'*) continue ;;
        *"$1"* | *"$2"*) if warns "$l"; then warned=1; fi; continue ;;
      esac
      log "output $l"
      case "$l" in
        'Token rotated'*) said_rotated=0 ;;
      esac
      if warns "$l"; then warned=1; fi
    done
    [ "$said_rotated" -eq 0 ] && [ -z "$warned" ]
  }

  warns() { case "$1" in *[Ww][Aa][Rr][Nn]* | *[Ee][Rr][Rr][Oo]* | *[Ff][Aa][Tt][Aa]*) return 0 ;; esac; return 1; }

  rotate_token() {
    begin rotate-token
    old=$(cat "$s/token") && new=$(openssl rand -hex 32) || return 1
    [ -n "$new" ] || return 1
    o=$(K3S_TOKEN=$old K3S_NEW_TOKEN=$new k3s token rotate 2>&1)
    r=$?
    printf '%s\n' "$o" | rotated "$new" "${old##*:}" && [ "$r" -eq 0 ] || return 1
    restart_k3s && mark token-rotated
  }

  mark() {
    for dep in $deployments; do
      x kc annotate deployment "$dep" --namespace "$ns" --overwrite "$a$1=true" || return 1
    done
  }

  check() {
    begin check
    o=$(kc get --raw /api 2>&1 >/dev/null) || { printf '%s\n' "$o" | said; return 1; }
    if [ -e "$d/copy.complete" ]; then
      c=$(answered "$d/copy")
      if [ "$c" != 401 ]; then echo "The API server answered $c to the old admin certificate." | said; return 1; fi
    fi
    ready
  }

  # Steps that are not undone: each is tried 5 times.
  again() {
    i=0
    until "$@"; do
      i=$((i + 1))
      if [ "$i" -ge 5 ]; then return 1; fi
      sleep 10
    done
  }

  scale_up() {
    for dep in $deployments; do
      n=$(annotation "$dep" replicas) || return 1
      if [ -n "$n" ]; then x kc scale deployment "$dep" --namespace "$ns" --replicas="$n" || return 1; fi
    done
  }

  # The mark goes first, so that a copy deleted in part is never complete; the new CA's folder,
  # whose keys the copy holds too, goes before the copy, so that nothing of it outlives the copy.
  delete_copy() { rm -f "$d/copy.complete" && rm -rf "$d/ca" && rm -rf "$d/copy"; }

  unannotate() {
    for dep in $deployments; do
      l=$(kc annotate deployment "$dep" --namespace "$ns" --list) || return 1
      keys=$(printf '%s\n' "$l" | grep "$ar" | cut -d= -f1)
      if [ -n "$keys" ]; then
        # shellcheck disable=SC2046,SC2086 # one argument for each key, which has no white space
        x kc annotate deployment "$dep" --namespace "$ns" $(printf '%s-\n' $keys) || return 1
      fi
    done
  }

  # Scales EHOS back, deletes the copy and removes the annotations, in that order, then ends with
  # `$1` and the step `$3`, or with `$2` and the step that failed 5 times.
  close() {
    begin scale-up
    again scale_up || result "$2" scale-up
    begin delete-copy
    again delete_copy || result "$2" delete-copy
    begin unannotate
    again unannotate || result "$2" unannotate
    rm -f "$d/checked"
    result "$1" "$3"
  }

  # Once the checks pass, the rotation is never undone (eh-os D-199): a mark on the disk says so to
  # a run again, which needs no API to read it.
  passed() { : >"$d/checked" && sync; }

  put_back() {
    begin put-back
    unit stop || return 1
    rm -rf "$s.ehosctl-new" && x cp -a "$d/copy" "$s.ehosctl-new" || return 1
    mv "$s" "$s.ehosctl-old" && mv "$s.ehosctl-new" "$s" && rm -rf "$s.ehosctl-old" || return 1
    unit start && wait_api || return 1
    begin check-old
    c=$(answered "$d/copy")
    if [ "$c" != 200 ]; then echo "The API server answered $c to the old admin certificate." | said; return 1; fi
    ready
  }

  # Undoes a rotation whose checks did not pass, which failed at `$1`. Without a complete copy, the
  # client CA did not change.
  undo() {
    failed=$1
    if [ -e "$d/copy.complete" ]; then
      put_back || result kept "$step"
      close undone unclean "$failed"
    fi
    start_k3s || result down "$failed"
    close stopped unclean "$failed"
  }

  # k3s that does not start: before the checks pass, put back the copy when it is complete.
  stuck() {
    if [ -e "$d/checked" ]; then result stalled "$step"; fi
    if [ -e "$d/copy.complete" ]; then undo "$step"; fi
    result down "$step"
  }

  # Runs the rotation from what the server holds: none begun, or one that a process before began.
  main() {
    log "run $run"
    for f in "$d"/process-*; do
      if [ "$f" != "$0" ] && [ -e "$f" ]; then rm -f "$f"; fi
    done
    repair || result failed repair
    start_k3s || stuck
    begin read
    annotated=$(for dep in $deployments; do kc annotate deployment "$dep" --namespace "$ns" --list || exit 1; done 2>&1) || {
      printf '%s\n' "$annotated" | said
      stuck
    }
    if ! printf '%s\n' "$annotated" | grep -q "$ar"; then
      if [ -e "$d/copy" ] || [ -e "$d/ca" ]; then
        begin delete-copy
        delete_copy || result failed delete-copy
        result cleared delete-copy
      fi
      if [ "$mode" != start ]; then result cleared -; fi
      rm -f "$d/checked"
      space || result failed space
      scale_down || undo "$step"
      recorded=$(annotation ehos-governance client-ca) || undo "$step"
      copy || undo "$step"
      new_ca || undo "$step"
      rotate_ca || undo "$step"
      rotate_token || undo "$step"
      check || undo "$step"
      passed || result unfinished check
      close finished unfinished -
    fi
    resume
  }

  resume() {
    for dep in $deployments; do
      n=$(annotation "$dep" replicas) || result failed read
      if [ -n "$n" ] && ! counted "$n"; then echo "The Deployment $dep records $n replicas." | said; result refused -; fi
    done
    recorded=$(annotation ehos-governance client-ca) || result failed read
    if [ -z "$recorded" ]; then recorded=$(annotation ehos-operator client-ca) || result failed read; fi
    if [ -z "$recorded" ]; then
      echo "No annotation records the client CA from before the rotation." | said
      result failed read
    fi
    if [ -e "$d/checked" ]; then close finished unfinished -; fi
    disk=$(fp "$s/tls/client-ca.crt") || result failed read
    if [ "$disk" = "$recorded" ]; then
      if [ -e "$d/copy.complete" ]; then undo -; fi
      close reverted unclean -
    fi
    token=$(annotation ehos-governance token-rotated) || result failed read
    if [ ! -e "$d/copy.complete" ]; then
      # Annotations without a copy only scale EHOS back (eh-os D-199), and a rotation never
      # finishes before its token is replaced: without that, the old token stays.
      if [ "$token" != true ]; then close partial unfinished -; fi
      check || result unfinished "$step"
      passed || result unfinished check
      close finished unfinished -
    fi
    if [ "$token" != true ]; then rotate_token || undo "$step"; fi
    check || undo "$step"
    passed || result unfinished check
    close finished unfinished -
  }

  main
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
    "unannotate" => "Removing the annotations of the rotation",
    "read" => "Reading the annotations of the rotation",
    "repair" => "Completing a put back of the copy of k3s that stopped"
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

  @doc """
  The script that the process of the rotation runs on the server, as root, with the id of its run,
  `start` or `again`, its folder and k3s's server folder.
  """
  @spec process_script() :: String.t()
  def process_script, do: @process_script

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
  The warnings about a rotation of the client CA that `status`, as `status/2` read it, shows on
  `server`, for `admin list` and `ehosctl doctor` (eh-os D-199): a process that runs; else k3s
  stopped, EHOS at zero replicas by a rotation that did not end, and a copy of k3s's server folder
  on the disk. A status that could not be read gives a warning that says so.
  """
  @spec warnings({:ok, status()} | {:error, Failure.message()}, Server.t()) ::
          [{String.t(), String.t() | nil}]
  def warnings({:ok, %{process?: true}}, server),
    do: [
      {"A rotation of the client CA runs on ehos-#{server.name}.",
       "Run `#{command(server, "rotate-client-ca")}` to follow it. EHOS stops and k3s " <>
         "restarts while it runs."}
    ]

  def warnings({:ok, status}, server),
    do:
      stopped_warning(status, server) ++
        zero_warning(status, server) ++ copy_warning(status, server)

  def warnings({:error, message}, server),
    do: [
      {"ehosctl could not read whether a rotation of the client CA runs on ehos-#{server.name}.",
       to_string(message)}
    ]

  defp stopped_warning(%{k3s?: true}, _server), do: []

  defp stopped_warning(_status, server),
    do: [
      {"k3s does not run on ehos-#{server.name}.",
       "If a rotation of the client CA stopped, run `#{command(server, "rotate-client-ca")}`: " <>
         "it starts k3s, then finishes the rotation or undoes it."}
    ]

  defp zero_warning(status, server) do
    if annotated?(status.deployments),
      do: [
        {"EHOS is at zero replicas on ehos-#{server.name}, because a rotation of the client CA " <>
           "did not end.",
         "The governance plane and the operator stay stopped until it ends. Run " <>
           "`#{command(server, "rotate-client-ca")}` to finish the rotation or undo it."}
      ],
      else: []
  end

  defp copy_warning(%{copy: :none}, _server), do: []

  defp copy_warning(_status, server),
    do: [
      {"A copy of the keys of k3s is on the disk of ehos-#{server.name}, in #{@dir}.",
       "It holds each key of the cluster. Run `#{command(server, "rotate-client-ca")}`: it " <>
         "finishes the rotation and deletes the copy, or undoes the rotation."}
    ]

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

  defp annotated?(deployments),
    do:
      Enum.any?(
        deployments,
        &(&1
          |> annotations()
          |> Map.keys()
          |> Enum.any?(fn key -> String.starts_with?(key, @annotation) end))
      )

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

  defp started(move, server, address) do
    mode = Atom.to_string(move)
    run = 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    server.progress.({:step, "Starting the rotation of the client CA on ehos-#{server.name}"})

    input = Enum.join([run, mode, @process_script], "\n")

    case Server.on_server(server, address, @start_script, input: input) do
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
      output: %{},
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
      {%{run: run} = result, run} -> {:ok, Map.put(result, :output, said_at(follow, result.step))}
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
    %{follow | step: step, output: Map.put(follow.output, step, [])}
  end

  defp entered({:output, line}, follow),
    do: %{follow | output: Map.update(follow.output, follow.step, [line], &[line | &1])}

  defp entered(:other, follow), do: follow

  # What the step a result names printed, the last time it ran, else what the last step printed: an
  # undo runs its own steps after the one that failed.
  defp said_at(follow, step),
    do: follow.output |> Map.get(step || follow.step, []) |> Enum.reverse()

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

  defp why(nil), do: "a rotation before stopped before its checks passed"
  defp why(step), do: "a step failed, at the step \"#{step_said(step)}\""

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
        "ehosctl undid the rotation of the client CA on ehos-#{server.name}, because " <>
          "#{why(result.step)}. It put back the copy of k3s from before the rotation, so " <>
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

  defp result_failure(%{outcome: "reverted"} = result, server),
    do:
      printed(
        "ehosctl ended a rotation of the client CA on ehos-#{server.name} that had stopped. " <>
          "The cluster trusts the client CA from before the rotation, and EHOS runs again. Run " <>
          "the command again to rotate the client CA.",
        result
      )

  defp result_failure(%{outcome: "partial"} = result, server),
    do:
      printed(
        "ehos-#{server.name} has a new client CA, but its server token is the one from before " <>
          "the rotation: a rotation stopped between the two, and its copy of k3s is gone, so " <>
          "ehosctl did not replace the token. EHOS runs again. Run the command again to " <>
          "replace both.",
        result
      )

  defp result_failure(%{outcome: "stalled"} = result, server),
    do:
      printed(
        "k3s does not start on ehos-#{server.name}#{at(result.step)}. The rotation of the client " <>
          "CA passed its checks, so ehosctl does not undo it, and EHOS stays at zero replicas. " <>
          "Repair k3s over SSH, as `sudo systemctl status k3s` shows, then run the command again " <>
          "to finish the rotation.",
        result
      )

  defp result_failure(%{outcome: "down"} = result, server),
    do:
      printed(
        "k3s does not start on ehos-#{server.name} after a step of the rotation of the client " <>
          "CA failed#{at(result.step)}. The client CA did not change, and EHOS stays at zero " <>
          "replicas. Repair k3s over SSH, as `sudo systemctl status k3s` shows, then run the " <>
          "command again.",
        result
      )

  defp result_failure(%{outcome: "unclean"} = result, server),
    do:
      printed(
        "ehosctl undid the rotation of the client CA on ehos-#{server.name}, but could not " <>
          "finish the undo#{at(result.step)}. The cluster trusts the client CA from before " <>
          "the rotation. EHOS can stay at zero replicas, and the copy of k3s can stay on the " <>
          "disk. Run the command again.",
        result
      )

  defp result_failure(%{outcome: "cleared", step: "delete-copy"} = result, server),
    do:
      printed(
        "ehosctl found no rotation of the client CA to finish on ehos-#{server.name}, and " <>
          "deleted a copy of k3s that no rotation recorded. Run the command again to start the " <>
          "rotation.",
        result
      )

  defp result_failure(%{outcome: "cleared"} = result, server),
    do:
      printed(
        "ehosctl found no rotation of the client CA to finish on ehos-#{server.name}. It " <>
          "started k3s if it was stopped. Run the command again to start the rotation.",
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
