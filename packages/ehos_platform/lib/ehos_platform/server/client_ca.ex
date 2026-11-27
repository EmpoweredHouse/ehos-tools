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
  # Whether the process runs and the last run are read together under the lock of a start, so that
  # a run that ends and another that starts between the two reads are never taken for one
  # (ehos-tools#1180); a server with no folder of the rotation has run none.
  @status_script ~S"""
  d=/var/lib/ehosctl/client-ca
  sudo -n true || exit 4
  e=$(mktemp) || exit 3
  trap 'rm -f "$e"' EXIT
  if sudo -n test -d "$d"; then
    pl=$(sudo -n flock -w 30 "$d/start.lock" sh -c 'l=$(cat "$1/current" 2>/dev/null) || l=; printf "%s %s\n" "$(systemctl is-active ehosctl-client-ca.service)" "${l:--}"' sh "$d") || exit 3
  else
    pl="$(systemctl is-active ehosctl-client-ca.service) -"
  fi
  printf 'k3s %s\n' "$(systemctl is-active k3s.service)"
  printf 'process %s\n' "${pl%% *}"
  if sudo -n test -e "$d/copy.complete"; then echo 'copy complete'
  elif sudo -n test -e "$d/copy" || sudo -n test -e "$d/ca"; then echo 'copy partial'
  else echo 'copy none'; fi
  printf 'last %s\n' "${pl#* }"
  printf '%s\n' '--- ehosctl client CA ---'
  sudo -n k3s kubectl get --request-timeout=30s deployments ehos-governance ehos-operator --namespace ehos-system --ignore-not-found -o json 2>"$e" || { printf '%s\n' '--- unread ---'; cat "$e"; }
  """

  # Standard input: the id of the run, `start` or `again`, the last run that ehosctl read (below),
  # the size of the process's script in bytes, then that script, which goes in a file of its own
  # run. A script that does not have that size did not arrive whole, as when SSH stops while it
  # arrives: the start deletes it and starts nothing (6), since a part of it would run as root
  # (ehos-tools#1186). It starts the process under a systemd unit of its own, which outlives the
  # SSH session, unless that unit runs already: 10. A lock holds a start at the same moment off
  # until the unit runs, which it then finds: it never moves the log of the run that starts, or
  # writes over its script; a start that finds the lock held starts nothing (12). Each run has its
  # log and result in `runs/`, named by its id, and `current` names the last run that began. A run's
  # files go together, by the age of the newest (ehos-tools#1180): those of the last 5 runs stay, of
  # each run of the last hour, longer than ehosctl follows one, and of the run before this one.
  # The start that finds the unit running prints the run `current` names under the lock. A first
  # start also gives the run that ehosctl read last, or `-`: when another run began since, it starts
  # nothing (11), since that run may have rotated the CA already.
  @start_script ~S"""
  set -u
  d=/var/lib/ehosctl/client-ca
  IFS= read -r run
  IFS= read -r mode
  IFS= read -r last
  IFS= read -r size
  case "$run" in ''|*[!0-9a-f]*) exit 2;; esac
  case "$size" in ''|*[!0-9]*) exit 2;; esac
  case "$mode" in start|again) ;; *) exit 2;; esac
  case "$last" in -|[0-9a-f]*) ;; *) exit 2;; esac
  case "$last" in -) ;; *[!0-9a-f]*) exit 2;; esac
  sudo -n true || exit 4
  sudo -n install -d -m 700 /var/lib/ehosctl "$d" || exit 3
  sudo -n flock -n -E 12 "$d/start.lock" sh -c '
    set -u
    d=$1 run=$2 mode=$3 last=$4 size=$5
    l=$(cat "$d/current" 2>/dev/null) || l=
    # A run that never ran is not the last one: a first start compares it with what it read.
    unname() {
      if [ -n "$l" ]; then printf "%s\n" "$l" >"$d/current.new" && mv -f "$d/current.new" "$d/current"; else rm -f "$d/current"; fi
    }
    if systemctl is-active --quiet ehosctl-client-ca.service; then printf "%s\n" "${l:--}"; exit 10; fi
    if [ "$mode" = start ] && [ "${l:--}" != "$last" ]; then exit 11; fi
    mkdir -p "$d/runs" || exit 3
    n=0
    for id in $(ls -t "$d/runs" | sed "s/[.].*//" | awk "!seen[\$0]++"); do
      case "$id" in ""|*[!0-9a-f]*) continue;; esac
      n=$((n + 1))
      if [ "$n" -le 5 ] || [ "$id" = "$l" ] || [ -n "$(find "$d/runs" -name "$id.*" -mmin -60)" ]; then continue; fi
      rm -f "$d/runs/$id".* || exit 3
    done
    printf "%s\n" "$run" >"$d/current.new" && mv -f "$d/current.new" "$d/current" || exit 3
    tee "$d/process-$run.new" >/dev/null || { rm -f "$d/process-$run.new"; unname; exit 3; }
    if [ "$(wc -c <"$d/process-$run.new" | tr -d " ")" != "$size" ]; then rm -f "$d/process-$run.new"; unname; exit 6; fi
    mv -f "$d/process-$run.new" "$d/process-$run.sh" || { unname; exit 3; }
    if ! systemd-run --unit=ehosctl-client-ca --collect --quiet --property=Type=exec /bin/sh "$d/process-$run.sh" "$run" "$mode" "$d" /var/lib/rancher/k3s/server; then
      unname
      exit 5
    fi
  ' sh "$d" "$run" "$mode" "$last" "$size"
  """

  # Standard input: how many bytes of the log ehosctl read already, and the id of the run it
  # follows, or `-` for the one `current` names. It prints that run's id, whether the process runs,
  # the run's result or `-`, then the rest of its log: the files of one run, whatever starts after.
  # The result is read before the log, and the process writes it last, so a result comes with the
  # whole log.
  @follow_script ~S"""
  d=/var/lib/ehosctl/client-ca
  IFS= read -r offset
  IFS= read -r run
  case "$offset" in ''|*[!0-9]*) exit 2;; esac
  case "$run" in -) ;; ''|*[!0-9a-f]*) exit 2;; esac
  sudo -n true || exit 4
  if [ "$run" = - ]; then run=$(sudo -n cat "$d/current" 2>/dev/null) || run=-; fi
  case "$run" in ''|*[!0-9a-f]*) run=-;; esac
  printf 'run %s\n' "$run"
  printf 'process %s\n' "$(systemctl is-active ehosctl-client-ca.service)"
  r=$(sudo -n cat "$d/runs/$run.result" 2>/dev/null) || r=-
  printf 'result %s\n' "${r:--}"
  printf '%s\n' '--- log ---'
  sudo -n tail -c "+$((offset + 1))" "$d/runs/$run.log" 2>/dev/null
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
  log() { printf '%s\n' "$*" >>"$d/runs/$run.log"; }
  said() { while IFS= read -r l; do log "output $l"; done; }
  begin() { step=$1; log "step $1"; }
  result() {
    printf '%s %s %s\n' "$run" "$1" "$2" >"$d/runs/$run.result.new" && mv -f "$d/runs/$run.result.new" "$d/runs/$run.result"
    # Its own script goes once it ends: the shell keeps the file it reads open. A process stopped
    # before leaves it, and the next run deletes it.
    rm -f "$0"
    exit 0
  }
  x() {
    o=$("$@" 2>&1)
    r=$?
    if [ -n "$o" ]; then printf '%s\n' "$o" | said; fi
    return "$r"
  }
  rt=30
  kc() { k3s kubectl --request-timeout="${rt}s" "$@"; }
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

  # Tries `$@` until it succeeds, for 5 minutes by the clock: each request may take the time left,
  # 30 seconds at most, and the pause between tries too, so that nothing stretches the wait. A status
  # of 2 stops at once.
  within() {
    t=$(date +%s) || return 1
    end=$((t + 300))
    while :; do
      budget || { rt=30; return 1; }
      "$@"
      r=$?
      if [ "$r" -eq 0 ]; then rt=30; return 0; fi
      if [ "$r" -eq 2 ]; then rt=30; return 1; fi
      budget || { rt=30; return 1; }
      sleep $((left < 5 ? left : 5))
    done
  }

  # Sets the time left before `end` and the time limit of the next request, 30 seconds at most;
  # fails when no time is left, or the clock cannot be read.
  budget() {
    t=$(date +%s) || return 1
    left=$((end - t))
    if [ "$left" -le 0 ]; then return 1; fi
    rt=$((left < 30 ? left : 30))
  }

  wait_api() { within up_k3s || { echo "The API server did not answer within 5 minutes." | said; return 1; }; }

  node_ready() {
    n=$(kc get nodes -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null)
    [ -n "$n" ] && ! printf '%s\n' "$n" | grep -qv '^True$'
  }

  ready() { within node_ready || { echo "The node is not Ready after 5 minutes." | said; return 1; }; }

  # No pod of EHOS's Deployments is left; 2 when kubectl fails, which a wait does not take for none.
  no_pods() {
    for selector in $selectors; do
      budget || return 1
      p=$(kc get pods --namespace "$ns" --selector "$selector" -o name 2>&1) || { printf '%s\n' "$p" | said; return 2; }
      if [ -n "$p" ]; then return 1; fi
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
  # When the copy is in place, as a folder moved aside shows, it is marked as put back before
  # anything starts k3s on it, also when the process stopped before it wrote the mark. Each branch
  # marks it, though the second alone would do, so that neither depends on the other.
  repair() {
    if [ ! -e "$s" ] && [ -e "$s.ehosctl-new" ]; then
      mv "$s.ehosctl-new" "$s" && : >"$d/restored" && sync || return 1
    fi
    if [ -e "$s.ehosctl-old" ]; then : >"$d/restored" && sync || return 1; fi
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
    # Each Deployment is scaled to zero by one patch that also records its count, the client CA in
    # force and that the rotation scaled it, under the resourceVersion of the read: a Deployment
    # that someone changed meanwhile, scaled to zero included, refuses the whole patch, and keeps
    # no mark that scaling back would trust. A patch that failed otherwise, as on a timeout, either
    # applied all of it or none.
    patches=
    selectors=
    for dep in $deployments; do
      state_of "$dep" || return 1
      if ! counted "$count"; then echo "The Deployment $dep has $count replicas. The rotation records 0 to 10." | said; return 1; fi
      patches="$patches $dep=$count=$version=$uid"
      selector=$(kc get deployment "$dep" --namespace "$ns" -o 'go-template={{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}') || return 1
      selectors="$selectors ${selector%,}"
    done
    for p in $patches; do
      dep=${p%%=*}
      rest=${p#*=}
      n=${rest%%=*}
      rest=${rest#*=}
      scaled_down "$dep" "$n" "${rest%%=*}" "${rest#*=}" || return 1
    done
    within no_pods || { echo "A pod of EHOS is still there after 5 minutes, or kubectl failed." | said; return 1; }
  }

  # The replica count of the Deployment `$1`, from what kubectl prints on standard output alone: a
  # warning on standard error is no count. It fails when kubectl does, or prints no number.
  replicas() {
    v=$(kc get deployment "$1" --namespace "$ns" -o 'jsonpath={.spec.replicas}' 2>"$d/kubectl.err")
    r=$?
    said <"$d/kubectl.err"
    if [ "$r" -ne 0 ]; then return 1; fi
    case "$v" in '' | *[!0-9]*) echo "kubectl gave no replica count for $1: $v" | said; return 1 ;; esac
    printf '%s\n' "$v"
  }

  # Patches the Deployment `$1`, read with the count `$2`, at the version `$3` and the UID `$4`. On
  # a conflict, or a failure that may have hidden a patch that applied, as a timeout, it reads the
  # Deployment again: the rotation's mark says the patch applied; a count changed, or another UID,
  # as a Deployment made again, stops it. Else it patches again, at the new version after a
  # conflict, since the Deployment controller writes the status, and at the same version after a
  # timeout, so that a patch still on its way can apply only once. 3 tries at most.
  scaled_down() {
    tries=0
    while :; do
      o=$(kc patch deployment "$1" --namespace "$ns" --type=merge -p "$(printf '{"metadata":{"uid":"%s","resourceVersion":"%s","annotations":{"%sreplicas":"%s","%sclient-ca":"%s","%sscaled":"true"}},"spec":{"replicas":0}}' "$4" "$3" "$a" "$2" "$a" "$ca" "$a")" 2>&1)
      r=$?
      if [ -n "$o" ]; then printf '%s\n' "$o" | said; fi
      if [ "$r" -eq 0 ]; then return 0; fi
      tries=$((tries + 1))
      if [ "$tries" -ge 3 ]; then return 1; fi
      state_of "$1" || return 1
      if [ "$uid" != "$4" ]; then echo "The Deployment $1 was made again meanwhile." | said; return 1; fi
      owned=$(annotation "$1" scaled) || return 1
      if [ "$owned" = true ]; then return 0; fi
      if [ "$count" != "$2" ]; then
        echo "Someone scaled the Deployment $1 from $2 to $count replicas meanwhile." | said
        return 1
      fi
      case "$o" in *'the object has been modified'*) set -- "$1" "$2" "$version" "$4" ;; esac
    done
  }

  # Reads the Deployment `$1`: its replica count in `count`, its resourceVersion in `version` and
  # its UID in `uid`.
  state_of() {
    v=$(kc get deployment "$1" --namespace "$ns" -o 'jsonpath={.spec.replicas} {.metadata.resourceVersion} {.metadata.uid}' 2>"$d/kubectl.err")
    r=$?
    said <"$d/kubectl.err"
    if [ "$r" -ne 0 ]; then return 1; fi
    count=${v%% *}
    version=${v#* }
    uid=${version#* }
    version=${version%% *}
    if digits "$count" && digits "$version" && named "$uid" && [ "$v" = "$count $version $uid" ]; then
      return 0
    fi
    echo "kubectl gave no replica count, version and UID for $1: $v" | said
    return 1
  }

  named() { case "$1" in '' | *[!0-9a-f-]*) return 1 ;; esac; }

  digits() { case "$1" in '' | *[!0-9]*) return 1 ;; esac; }

  counted() {
    case "$1" in '' | *[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 2 ] && [ "$1" -le 10 ]
  }

  copy() {
    begin stop-k3s
    # Right before the stop: a pod of EHOS that someone started since the wait stops the rotation.
    end=$(($(date +%s) + 60))
    no_pods || { echo "A pod of EHOS runs again, or kubectl failed." | said; return 1; }
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

  # Scales each Deployment that the rotation's patch scaled to zero, as its mark says, back to its
  # recorded count, and removes the mark, in one patch at the version read: a Deployment that someone
  # scaled since keeps their count, and loses the mark alone, so that a run again never takes a later
  # zero for the rotation's. A conflict from a status write reads it again, 3 times at most.
  scale_up() {
    for dep in $deployments; do
      tries=0
      while :; do
        # The version first: the patch at it applies only if the annotations read after it are
        # still the Deployment's, not those of one made again in between.
        state_of "$dep" || return 1
        owned=$(annotation "$dep" scaled) || return 1
        if [ "$owned" != true ]; then break; fi
        n=$(annotation "$dep" replicas) || return 1
        if [ "$count" = 0 ] && [ -n "$n" ]; then
          patch=$(printf '{"metadata":{"uid":"%s","resourceVersion":"%s","annotations":{"%sscaled":null}},"spec":{"replicas":%s}}' "$uid" "$version" "$a" "$n")
        else
          if [ -z "$n" ]; then
            echo "The Deployment $dep has no recorded count, so the rotation leaves it at $count replicas." | said
          elif [ "$count" != "$n" ]; then
            echo "The Deployment $dep has $count replicas, not 0, so the rotation does not scale it." | said
          fi
          patch=$(printf '{"metadata":{"uid":"%s","resourceVersion":"%s","annotations":{"%sscaled":null}}}' "$uid" "$version" "$a")
        fi
        o=$(kc patch deployment "$dep" --namespace "$ns" --type=merge -p "$patch" 2>&1)
        r=$?
        if [ -n "$o" ]; then printf '%s\n' "$o" | said; fi
        if [ "$r" -eq 0 ]; then break; fi
        tries=$((tries + 1))
        if [ "$tries" -ge 3 ]; then return 1; fi
      done
    done
  }

  # The mark goes first, so that a copy deleted in part is never complete; the new CA's folder,
  # whose keys the copy holds too, goes before the copy, so that nothing of it outlives the copy.
  delete_copy() { rm -f "$d/copy.complete" && rm -rf "$d/ca" && rm -rf "$d/copy"; }

  # Removes the annotations at the version read, after which no record of the rotation is left:
  # a scale-down patch whose answer was lost, and that applied only after scaling back looked, has
  # left its mark by then, and that Deployment is scaled back first; one that would apply later is
  # refused, since this changes the version of each Deployment, one with no annotation left too.
  unannotate() {
    for each in $deployments; do
      state_of "$each" || return 1
      listed "$each" || return 1
      if printf '%s\n' "$l" | grep -qx "${a}scaled=true"; then
        scale_up || return 1
        state_of "$each" || return 1
        listed "$each" || return 1
        if printf '%s\n' "$l" | grep -qx "${a}scaled=true"; then return 1; fi
      fi
      keys=$(printf '%s\n' "$l" | grep "$ar" | cut -d= -f1)
      if [ -z "$keys" ]; then
        # A write that changes the version alone, and leaves nothing.
        x kc annotate deployment "$each" --namespace "$ns" --resource-version="$version" "${a}closed=$run" || return 1
        state_of "$each" || return 1
        keys="${a}closed"
      fi
      # shellcheck disable=SC2046,SC2086 # one argument for each key, which has no white space
      x kc annotate deployment "$each" --namespace "$ns" --resource-version="$version" $(printf '%s-\n' $keys) || return 1
    done
  }

  # The annotations of the Deployment `$1`, in `l`; fails, with kubectl's output in the log, when
  # kubectl does.
  listed() {
    l=$(kc annotate deployment "$1" --namespace "$ns" --list 2>&1) || { printf '%s\n' "$l" | said; return 1; }
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
    rm -f "$d/checked" "$d/restored"
    result "$1" "$3"
  }

  # Once the checks pass, the rotation is never undone (eh-os D-199): a mark on the disk says so to
  # a run again, which needs no API to read it.
  passed() { : >"$d/checked" && sync; }

  put_back() {
    begin put-back
    unit stop || return 1
    rm -rf "$s.ehosctl-new" && x cp -a "$d/copy" "$s.ehosctl-new" || return 1
    # Marked as soon as the copy is in place, before k3s can start on it and take writes. `repair`
    # deletes the folder moved aside when this cannot.
    mv "$s" "$s.ehosctl-old" && mv "$s.ehosctl-new" "$s" && : >"$d/restored" && sync || return 1
    rm -rf "$s.ehosctl-old" || return 1
    back_checked
  }

  # Starts k3s on the copy put back, and checks the old admin certificate and the node.
  back_checked() {
    start_k3s || return 1
    begin check-old
    c=$(answered "$d/copy")
    if [ "$c" != 200 ]; then echo "The API server answered $c to the old admin certificate." | said; return 1; fi
    ready
  }

  # Undoes a rotation whose checks did not pass, which failed at `$1`. Without a complete copy, the
  # client CA did not change.
  undo() {
    failed=$1
    # Once the copy is back, the cluster may have taken writes: it is never put back again. An undo
    # that stopped after it checks the copy that is in place, then cleans up.
    if [ -e "$d/restored" ]; then
      back_checked || result kept "$step"
      close undone unclean "$failed"
    fi
    if [ -e "$d/copy.complete" ]; then
      put_back || result kept "$step"
      close undone unclean "$failed"
    fi
    start_k3s || result down "$failed"
    close stopped unclean "$failed"
  }

  # k3s that does not start: before the checks pass, undo with a complete copy, which puts it back,
  # or checks it when it is back already.
  stuck() {
    if [ -e "$d/checked" ]; then result stalled "$step"; fi
    if [ -e "$d/copy.complete" ]; then undo "$step"; fi
    result down "$step"
  }

  # Runs the rotation from what the server holds: none begun, or one that a process before began.
  main() {
    mkdir -p "$d/runs"
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
      rm -f "$d/checked" "$d/restored"
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
    # The cleanup writes its closing mark on a Deployment with no annotation left, then removes it:
    # a process stopped between the two leaves that mark alone, and no record to resume from
    # (ehos-tools#1180). Only the disk says how that rotation ended: it finishes it when its checks
    # passed, and else ends with what any rotation that stopped before them can have left.
    if ! printf '%s\n' "$annotated" | grep "$ar" | grep -qv "${ar}closed="; then
      if [ -e "$d/checked" ]; then close finished unfinished -; fi
      close ended unclosed -
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
  is, the id of the last run that began, or `-`, and EHOS's Deployments, or what kubectl printed
  when it could not read them.
  """
  @type status :: %{
          k3s?: boolean(),
          process?: boolean(),
          copy: :none | :partial | :complete,
          last: String.t(),
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
  The script that reads what the server holds of the rotation, in the form `parse_status/1` reads.
  """
  @spec status_script() :: String.t()
  def status_script, do: @status_script

  @doc """
  The script that starts the process of the rotation on the server. Its standard input is the id
  of the run, `start` or `again`, the last run that ehosctl read or `-`, the size of
  `process_script/0` in bytes, then `process_script/0`.
  """
  @spec start_script() :: String.t()
  def start_script, do: @start_script

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
         {:ok, run} <- started(move, status.last, server, address),
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
      ...>   "k3s active\\nprocess inactive\\ncopy none\\nlast -\\n--- ehosctl client CA ---\\n" <>
      ...>     ~s({"items": []}) <> "\\n"
      ...> )
      {:ok, %{k3s?: true, process?: false, copy: :none, last: "-", deployments: []}}

      iex> EhosPlatform.Server.ClientCa.parse_status(
      ...>   "k3s inactive\\nprocess inactive\\ncopy complete\\nlast 0123456789abcdef\\n--- ehosctl client CA ---\\n" <>
      ...>     "--- unread ---\\nThe connection to the server 127.0.0.1:6443 was refused\\n"
      ...> )
      {:ok,
       %{
         k3s?: false,
         process?: false,
         copy: :complete,
         last: "0123456789abcdef",
         deployments: {:unread, "The connection to the server 127.0.0.1:6443 was refused\\n"}
       }}
  """
  @spec parse_status(String.t()) :: {:ok, status()} | {:error, String.t()}
  def parse_status(output) do
    with [head, deployments] <- String.split(output, @marker <> "\n", parts: 2),
         ["k3s " <> k3s, "process " <> process, "copy " <> copy, "last " <> last] <-
           String.split(head, "\n", trim: true),
         {:ok, copy} <- copy(copy),
         true <- last == "-" or last =~ ~r/\A[0-9a-f]+\z/,
         {:ok, deployments} <- deployments(deployments) do
      {:ok,
       %{
         k3s?: k3s == "active",
         process?: process == "active",
         copy: copy,
         last: last,
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
    cond do
      not annotated?(status.deployments) ->
        []

      Enum.any?(status.deployments, &stopped_by_rotation?/1) ->
        [
          {"#{stopped_said(status.deployments)} on ehos-#{server.name}, because a rotation of " <>
             "the client CA did not end.",
           "EHOS stays stopped until the rotation ends. Run " <>
             "`#{command(server, "rotate-client-ca")}` to finish the rotation or undo it."}
        ]

      true ->
        [
          {"A rotation of the client CA did not end on ehos-#{server.name}.",
           "Its annotations are still on the Deployments of EHOS. Run " <>
             "`#{command(server, "rotate-client-ca")}` to finish the rotation or undo it."}
        ]
    end
  end

  # At zero replicas, by the rotation's patch, with a recorded count that is not zero: a Deployment
  # that its owner keeps at zero, or scaled to zero meanwhile, is not one that the rotation stopped.
  defp stopped_by_rotation?(deployment) do
    annotations = annotations(deployment)

    get_in(deployment, ["spec", "replicas"]) == 0 and
      annotations[@annotation <> "scaled"] == "true" and
      annotations[@annotation <> "replicas"] not in [nil, "0"]
  end

  defp stopped_said(deployments) do
    case for(d <- deployments, stopped_by_rotation?(d), do: get_in(d, ["metadata", "name"])) do
      [one] -> "The Deployment #{one} of EHOS is at zero replicas"
      both -> "The Deployments #{Enum.join(both, " and ")} of EHOS are at zero replicas"
    end
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

      pending_removals(state) != [] ->
        {:error, removals_said(pending_removals(state), server)}

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

  # A removal that GCP's guest agent can undo leaves a comment with the key: until it finishes, that
  # key can log in, and copy the admin certificate of k3s that the rotation makes.
  defp pending_removals(state),
    do: for(%{kind: :removed, name: name} <- state.keys, uniq: true, do: name)

  defp removals_said(names, server) do
    commands = Enum.map_join(names, ", ", &"`#{command(server, "admin remove #{&1}")}`")

    "ehos-#{server.name} has not finished the removal of #{Enum.join(names, ", ")}, and GCP's " <>
      "guest agent can put their key back, so ehosctl did not start the rotation. Run " <>
      "#{commands} until each finishes, then run the command again."
  end

  defp allowed(:start, server, address) do
    with {:ok, state} <- Administrators.read(server, address),
         do: ready(state, Administrators.provisioning(server), server)
  end

  defp allowed(_again_or_follow, _server, _address), do: :ok

  # The run that `current` named when ehosctl read the server, which the start of a run writes before
  # the run's unit starts: so a start that another ehosctl is making meanwhile is never taken for it.
  defp started(:follow, last, server, _address) do
    server.progress.({:step, "Following the rotation that runs on ehos-#{server.name}"})
    {:ok, if(last == "-", do: nil, else: last)}
  end

  defp started(move, last, server, address) do
    mode = Atom.to_string(move)
    run = 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    server.progress.({:step, "Starting the rotation of the client CA on ehos-#{server.name}"})

    input = Enum.join([run, mode, last, byte_size(@process_script), @process_script], "\n")

    case Server.on_server(server, address, @start_script, input: input) do
      {_output, 0} -> {:ok, run}
      {output, 10} -> started(:follow, running(output), server, address)
      {_output, 11} -> {:error, another_run(server)}
      {_output, 12} -> {:error, another_start(server)}
      {_output, 6} -> {:error, cut_script(server)}
      result -> failed(result, "ehosctl could not start the rotation on ehos-#{server.name}.")
    end
  end

  # The run that the start found running, as it printed it under the lock.
  defp running(output) do
    run = output |> String.split("\n", trim: true) |> List.last("")
    if run =~ ~r/\A[0-9a-f]+\z/, do: run, else: "-"
  end

  defp another_start(server),
    do:
      "Another ehosctl is starting a rotation of the client CA on ehos-#{server.name}, or " <>
        "reading its state, at this moment, so ehosctl started none. Run the command again in a " <>
        "moment: it follows a rotation that started, or starts one."

  defp cut_script(server),
    do:
      "The connection to ehos-#{server.name} stopped before the script of the rotation arrived " <>
        "whole, so ehosctl started no rotation. Run the command again."

  defp another_run(server),
    do:
      "Another ehosctl ran a rotation of the client CA on ehos-#{server.name} after this one " <>
        "read the server, so ehosctl did not start one more. Run " <>
        "`#{command(server, "admin list")}` to see the state of the server, then run the " <>
        "command again if you still need a rotation."

  # `run` is the id of the run that ehosctl started, or `nil` when it follows one that ran
  # already, whose id the server gives on the first read.
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
    |> Server.on_server(follow.address, @follow_script,
      input: "#{follow.offset}\n#{follow.run || "-"}\n"
    )
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

  defp read_poll(["run " <> run, "process " <> process, "result " <> result], log, follow)
       when run != "-" do
    follow = logged(%{follow | run: follow.run || run}, log)

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
        "ehosctl could not undo the rotation of the client CA on ehos-#{server.name} with its " <>
          "copy of k3s from before the rotation#{at(result.step)}. The copy stays in #{@dir}/copy on " <>
          "the server, and EHOS stays at zero replicas. Over SSH, `sudo systemctl status k3s` " <>
          "and `sudo journalctl -u k3s` show why k3s does not start. Repair it, then run the " <>
          "command again.",
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

  defp result_failure(%{outcome: "ended"} = result, server),
    do:
      printed(
        "ehosctl finished the cleanup of a rotation of the client CA on ehos-#{server.name} " <>
          "that stopped before its checks passed. The client CA, the server token of k3s, or " <>
          "both, can be the ones from before the rotation. EHOS runs again. Run the command " <>
          "again to replace both.",
        result
      )

  defp result_failure(%{outcome: "unclosed"} = result, server),
    do:
      printed(
        "ehosctl could not finish the cleanup#{at(result.step)}. It cleans up after a " <>
          "rotation of the client CA on ehos-#{server.name} that stopped before its checks " <>
          "passed. The client CA, the server token of k3s, or both, can be the ones from before " <>
          "the rotation. Run the command again to finish the cleanup.",
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
