defmodule EhosPlatform.Server.ClientCaProcessTest do
  # The process of the rotation (eh-os D-199, "Existing installations", step 3), run with `sh`
  # against programs that stand in for k3s, systemctl, openssl and curl. They keep a small model
  # of a one-node k3s server in the test's folder: the client CA in the datastore
  # (`server/db/client-ca`, so that a copy of the server folder holds it) and on the disk
  # (`server/tls/client-ca.crt`, written from the datastore when k3s starts), the server token,
  # the admin certificate k3s issues at start, and EHOS's Deployments with their replicas,
  # annotations and pods. `token rotate` saves the CA on the disk into the datastore, as k3s does.
  # A test makes the next matching call fail (`fail`), or kills the process right after it
  # (`kill`), then reads what the server holds, and runs the process again.
  use ExUnit.Case, async: true

  alias EhosPlatform.Server.ClientCa

  @moduletag :tmp_dir

  @annotation "ehos.empowered.house/client-ca-rotation-"

  # Sourced by every program below: records the call, fails it when `fail` names it, and gives
  # `after_call`, which kills the process when `kill` names the call.
  @prelude ~S"""
  F=$FAKE
  S=$FAKE/server
  call="$(basename "$0") $*"
  printf '%s\n' "$call" >>"$F/calls"
  fired() {
    [ -s "$F/$1" ] || return 1
    p=
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      case "$call" in *"$l"*) p=$l; break ;; esac
    done <"$F/$1"
    [ -n "$p" ] || return 1
    grep -vxF "$p" "$F/$1" >"$F/$1.new"; mv "$F/$1.new" "$F/$1"
  }
  if fired fail; then echo "injected failure of $call"; exit 1; fi
  after_call() { if fired kill; then : >"$F/killed"; kill -9 "$(cat "$F/pid")"; fi; }
  active() { [ "$(cat "$F/k3s")" = active ]; }
  # A Deployment's resourceVersion: it changes with each write, and never comes back, as an API
  # server's does, and with each change a test makes to its files.
  version() {
    printf '%s%s' "$(cat "$F/deploy/$1/writes" 2>/dev/null || echo 0)" \
      "$(cat "$F/deploy/$1/replicas" "$F/deploy/$1/annotations" "$F/deploy/$1/status" 2>/dev/null | cksum | cut -d' ' -f1)"
  }
  written() { echo $(( $(cat "$F/deploy/$1/writes" 2>/dev/null || echo 0) + 1 )) >"$F/deploy/$1/writes"; }
  """

  @programs %{
    "systemctl" => ~S"""
    case "$1" in
      is-active) active; exit $? ;;
      stop) echo inactive >"$F/k3s" ;;
      start|restart)
        if [ ! -d "$S/db" ]; then echo "Job for k3s.service failed."; exit 1; fi
        cp "$S/db/client-ca" "$S/tls/client-ca.crt"
        echo "admin-of-$(cat "$S/tls/client-ca.crt")" >"$S/tls/client-admin.crt"
        if [ -s "$F/broken" ]; then echo inactive >"$F/k3s"; rm "$F/broken"; else echo active >"$F/k3s"; fi
        ;;
    esac
    after_call
    """,
    "k3s" => ~S"""
    case "$1" in
      certificate)
        active || { echo "connection refused"; exit 1; }
        path=$4
        if [ "$5" != --force ]; then echo "certificate error ID 1234"; exit 1; fi
        if [ ! -s "$path/tls/client-ca.crt" ] || [ -s "$F/warn" ]; then
          echo 'WARN[0000] open tls/client-ca.crt: no such file or directory'
        else
          cp "$path/tls/client-ca.crt" "$S/db/client-ca"
        fi
        echo "certificates saved to datastore"
        ;;
      token)
        active || { echo "connection refused"; exit 1; }
        if [ "$K3S_TOKEN" != "$(cat "$S/token")" ]; then echo "token mismatch"; exit 1; fi
        printf '%s\n' "$K3S_NEW_TOKEN" >"$S/token"
        cp "$S/tls/client-ca.crt" "$S/db/client-ca"
        # As k3s prints it, and the token on a line of its own, which k3s does not print.
        printf '\033[33mWARNING\033[0m: Recommended to keep a record of the old token. If restoring from a snapshot, you must use the token associated with that snapshot.\n'
        printf 'Token rotated, restart k3s nodes with new token\n%s\n' "$K3S_NEW_TOKEN"
        ;;
      kubectl)
        active || { echo "The connection to the server 127.0.0.1:6443 was refused"; exit 1; }
        shift 2
        verb=$1
        case "$verb $2 $3" in
          "get --raw "*) ;;
          "get nodes "*) printf 'True\n' ;;
          "get pods "*)
            dep=${6#app=}
            if [ "$(cat "$F/deploy/$dep/pods")" -gt 0 ]; then echo "pod/$dep-1"; fi
            ;;
          "get deployment "*)
            dep=$3
            [ -d "$F/deploy/$dep" ] || { echo "deployments.apps \"$dep\" not found"; exit 1; }
            case "$7" in
              *resourceVersion*) printf '%s %s %s' "$(cat "$F/deploy/$dep/replicas")" "$(version "$dep")" "$(cat "$F/deploy/$dep/uid")" ;;
              jsonpath=*) cat "$F/deploy/$dep/replicas" ;;
              go-template=*) printf 'app=%s,' "$dep" ;;
            esac
            ;;
          "patch deployment "*)
            # A merge patch with a resourceVersion and a UID, refused whole as an API server
            # refuses it: the version first, then the UID, which cannot change.
            dep=$3
            patch=$8
            want=$(printf '%s' "$patch" | sed -n 's/.*"resourceVersion":"\([0-9]*\)".*/\1/p')
            if [ "$want" != "$(version "$dep")" ]; then
              echo "Error from server (Conflict): Operation cannot be fulfilled on deployments.apps \"$dep\": the object has been modified"
              exit 1
            fi
            want=$(printf '%s' "$patch" | sed -n 's/.*"uid":"\([^"]*\)".*/\1/p')
            if [ "$want" != "$(cat "$F/deploy/$dep/uid")" ]; then
              echo "The Deployment \"$dep\" is invalid: metadata.uid: Invalid value: \"$want\": field is immutable"
              exit 1
            fi
            for key in replicas client-ca scaled; do
              k="ehos.empowered.house/client-ca-rotation-$key"
              case "$patch" in
                *"\"$k\":null"*)
                  grep -v "^$k=" "$F/deploy/$dep/annotations" >"$F/a.new"; mv "$F/a.new" "$F/deploy/$dep/annotations" ;;
                *"\"$k\":\""*)
                  value=$(printf '%s' "$patch" | sed -n "s|.*\"$k\":\"\([^\"]*\)\".*|\1|p")
                  grep -v "^$k=" "$F/deploy/$dep/annotations" >"$F/a.new"
                  printf '%s\n' "$k=$value" >>"$F/a.new"
                  mv "$F/a.new" "$F/deploy/$dep/annotations" ;;
              esac
            done
            n=$(printf '%s' "$patch" | sed -n 's/.*"spec":{"replicas":\([0-9]*\)}.*/\1/p')
            if [ -n "$n" ]; then
              echo "$n" >"$F/deploy/$dep/replicas"
              echo "$n" >"$F/deploy/$dep/pods"
            fi
            written "$dep"
            ;;
          "scale deployment "*)
            dep=$3
            n=${6#--replicas=}
            case "${7:-}" in
              --current-replicas=*)
                now=$(cat "$F/deploy/$dep/replicas")
                if [ "$now" != "${7#--current-replicas=}" ]; then
                  echo "Expected replicas to be ${7#--current-replicas=}, was $now"; exit 1
                fi ;;
            esac
            echo "$n" >"$F/deploy/$dep/replicas"
            echo "$n" >"$F/deploy/$dep/pods"
            written "$dep"
            ;;
          "annotate deployment "*)
            dep=$3
            shift 5
            if [ "${1:-}" = --list ]; then cat "$F/deploy/$dep/annotations"; exit 0; fi
            for arg in "$@"; do
              case "$arg" in
                --resource-version=*)
                  if [ "${arg#--resource-version=}" != "$(version "$dep")" ]; then
                    echo "Error from server (Conflict): Operation cannot be fulfilled on deployments.apps \"$dep\": the object has been modified"
                    exit 1
                  fi ;;
              esac
            done
            written "$dep"
            for arg in "$@"; do
              case "$arg" in
                --overwrite | --resource-version=*) ;;
                *-) grep -v "^${arg%-}=" "$F/deploy/$dep/annotations" >"$F/a.new"; mv "$F/a.new" "$F/deploy/$dep/annotations" ;;
                *) grep -v "^${arg%%=*}=" "$F/deploy/$dep/annotations" >"$F/a.new"
                   printf '%s\n' "$arg" >>"$F/a.new"; mv "$F/a.new" "$F/deploy/$dep/annotations" ;;
              esac
            done
            ;;
          *) echo "unknown kubectl call: $*"; exit 1 ;;
        esac
        ;;
    esac
    after_call
    """,
    "openssl" => ~S"""
    next() { n=$(( $(cat "$F/count.$1" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$F/count.$1"; }
    case "$1" in
      ecparam) eval "out=\${$#}"; next key; echo "key-$n" >"$out" ;;
      req) eval "out=\${$#}"; next ca; echo "ca-$n" >"$out" ;;
      x509) printf 'sha256 Fingerprint=%s\n' "$(cksum <"$3" | cut -d' ' -f1)" ;;
      rand) next token; echo "token$n" ;;
    esac
    after_call
    """,
    "curl" => ~S"""
    active || { printf 000; exit 7; }
    cert=
    while [ $# -gt 0 ]; do if [ "$1" = --cert ]; then cert=$2; fi; shift; done
    if [ "$(cat "$cert")" = "admin-of-$(cat "$S/tls/client-ca.crt")" ]; then printf 200; else printf 401; fi
    after_call
    """,
    "df" => ~S"""
    if [ -s "$F/df" ]; then printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/x 1 1 %s 1%% /\n' "$(cat "$F/df")"; exit 0; fi
    exec /bin/df "$@"
    """,
    "timeout" => ~S"""
    shift
    exec "$@"
    """,
    # The clock moves only when the process sleeps, so that a wait of 5 minutes ends at once.
    "sleep" => ~S"""
    t=$(cat "$F/clock" 2>/dev/null || echo 1000000)
    echo $((t + $1)) >"$F/clock"
    """,
    "date" => ~S"""
    if [ "$1" = +%s ]; then cat "$F/clock" 2>/dev/null || echo 1000000; exit 0; fi
    exec /bin/date "$@"
    """
  }

  setup %{tmp_dir: dir} do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)

    for {name, body} <- @programs do
      path = Path.join(bin, name)
      File.write!(path, "#!/bin/sh\n" <> @prelude <> body)
      File.chmod!(path, 0o755)
    end

    # grep as it is, with each call recorded: a token must never be on its command line.
    grep = Path.join(bin, "grep")

    File.write!(
      grep,
      ~s(#!/bin/sh\nprintf '%s\\n' "grep $*" >>"$FAKE/calls"\nexec #{grep_path()} "$@"\n)
    )

    File.chmod!(grep, 0o755)

    server = Path.join(dir, "server")

    for {file, contents} <- [
          {"tls/client-ca.crt", "ca-old"},
          {"tls/client-ca.key", "key-old"},
          {"tls/client-admin.crt", "admin-of-ca-old"},
          {"tls/client-admin.key", "admin-key"},
          {"tls/server-ca.crt", "server-ca"},
          {"tls/server-ca.key", "server-ca-key"},
          {"tls/request-header-ca.crt", "request-header-ca"},
          {"tls/request-header-ca.key", "request-header-ca-key"},
          {"tls/service.key", "service-key"},
          {"tls/etcd/peer-ca.crt", "peer-ca"},
          {"tls/etcd/peer-ca.key", "peer-ca-key"},
          {"tls/etcd/server-ca.crt", "etcd-server-ca"},
          {"tls/etcd/server-ca.key", "etcd-server-ca-key"},
          {"db/client-ca", "ca-old"},
          {"token", "K10abc::server:old"}
        ] do
      path = Path.join(server, file)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents <> "\n")
    end

    for deployment <- ["ehos-governance", "ehos-operator"] do
      place = Path.join([dir, "deploy", deployment])
      File.mkdir_p!(place)
      File.write!(Path.join(place, "replicas"), "1\n")
      File.write!(Path.join(place, "pods"), "1\n")
      File.write!(Path.join(place, "annotations"), "")

      File.write!(
        Path.join(place, "uid"),
        "0a1b2c3d-#{if deployment == "ehos-governance", do: "1", else: "2"}\n"
      )
    end

    File.write!(Path.join(dir, "k3s"), "active\n")
    File.mkdir_p!(Path.join(dir, "ehosctl"))

    %{dir: dir}
  end

  test "replaces the client CA, then the token, and finishes", %{dir: dir} do
    assert run(dir) == {"finished", "-"}

    assert server(dir) == %{
             k3s: "active",
             disk_ca: "ca-1",
             datastore_ca: "ca-1",
             token: "token1",
             replicas: ["1", "1"],
             annotations: [[], []],
             copy?: false
           }

    assert steps(dir) == [
             "read",
             "space",
             "scale-down",
             "stop-k3s",
             "copy",
             "start-k3s",
             "new-ca",
             "rotate-ca",
             "restart-k3s",
             "rotate-token",
             "restart-k3s",
             "check",
             "scale-up",
             "delete-copy",
             "unannotate"
           ]

    # The CA rotation comes before the token, with a restart between them, and the old admin
    # certificate is checked with the copy's.
    assert calls(dir, "k3s certificate rotate-ca") == [
             "k3s certificate rotate-ca --path #{dir}/ehosctl/ca --force"
           ]

    assert log(dir) =~ "output Token rotated"

    for place <- [log(dir), journal(dir), File.read!(Path.join(dir, "calls"))] do
      refute place =~ "token1"
      refute place =~ "server:old"
    end
  end

  test "keeps the other CAs and keys of the cluster in the path it gives rotate-ca", %{
    dir: dir
  } do
    File.write!(Path.join(dir, "kill"), "k3s certificate rotate-ca\n")
    assert {"", _killed} = run(dir)

    given = Path.join([dir, "ehosctl", "ca", "tls"])

    for file <- ~w(server-ca.crt server-ca.key request-header-ca.crt request-header-ca.key
                   service.key etcd/peer-ca.crt etcd/peer-ca.key etcd/server-ca.crt
                   etcd/server-ca.key) do
      assert File.read!(Path.join(given, file)) ==
               File.read!(Path.join([dir, "server/tls", file]))
    end

    assert File.read!(Path.join(given, "client-ca.crt")) == "ca-1\n"
  end

  test "undoes a failure after rotate-ca: the old CA, the old token, EHOS back", %{dir: dir} do
    File.write!(Path.join(dir, "fail"), "k3s token rotate\n")

    assert run(dir) == {"undone", "rotate-token"}
    assert server(dir) == unchanged()
    assert "put-back" in steps(dir) and "check-old" in steps(dir)
  end

  test "undoes a failure after token rotate", %{dir: dir} do
    File.write!(Path.join(dir, "fail"), "kubectl --request-timeout=30s get --raw /api\n")

    assert run(dir) == {"undone", "check"}
    assert server(dir) == unchanged()
  end

  test "gives each start, restart and stop of k3s 5 minutes, and undoes when one runs out", %{
    dir: dir
  } do
    File.write!(Path.join(dir, "fail"), "timeout 300 systemctl restart k3s.service\n")

    assert run(dir) == {"undone", "restart-k3s"}
    assert server(dir) == unchanged()

    # Each start, restart and stop of systemctl comes through timeout.
    calls = dir |> Path.join("calls") |> File.read!() |> String.split("\n")

    for [before, "systemctl " <> verb] <- Enum.chunk_every(calls, 2, 1, :discard),
        verb =~ ~r/^(start|restart|stop) /,
        do: assert(before == "timeout 300 systemctl " <> verb)

    assert "timeout 300 systemctl restart k3s.service" in calls
  end

  test "says when systemctl did not end within 5 minutes", %{dir: dir} do
    wrap(dir, "timeout", ~S"""
    case "$*" in *"systemctl restart"*) exit 124 ;; esac
    """)

    assert run(dir) == {"undone", "restart-k3s"}
    assert log(dir) =~ "output systemctl restart k3s.service did not end within 5 minutes."
  end

  test "undoes when token rotate warns on a line that holds a token", %{dir: dir} do
    wrap(dir, "k3s", ~S"""
    case "$*" in "token rotate") echo "level=warning msg=\"token $K3S_NEW_TOKEN is weak\"" ;; esac
    """)

    assert run(dir) == {"undone", "rotate-token"}
    refute log(dir) =~ "token1"
  end

  test "deletes the scripts of earlier runs, and keeps its own", %{dir: dir} do
    File.write!(Path.join([dir, "ehosctl", "process-00000000000000aa.sh"]), "")
    File.write!(Path.join([dir, "ehosctl", "process-00000000000000bb.new"]), "")

    assert run(dir) == {"finished", "-"}

    assert dir
           |> Path.join("ehosctl")
           |> File.ls!()
           |> Enum.filter(&String.starts_with?(&1, "process-")) == ["process-0123456789abcdef.sh"]
  end

  test "undoes when rotate-ca warns and exits 0, as with files out of place", %{dir: dir} do
    File.write!(Path.join(dir, "warn"), "1\n")

    assert run(dir) == {"undone", "rotate-ca"}
    assert server(dir) == unchanged()
    assert log(dir) =~ "output WARN[0000] open tls/client-ca.crt"
  end

  test "keeps the copy and EHOS at zero when the cluster does not come back", %{dir: dir} do
    File.write!(Path.join(dir, "fail"), "k3s token rotate\n")
    # k3s starts after the copy, and stays stopped after the put back.
    wrap(dir, "systemctl", ~S"""
    if [ "$1" = start ]; then
      n=$(( $(cat "$F/starts" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$F/starts"
      if [ "$n" -ge 2 ]; then echo 1 >"$F/broken"; fi
    fi
    """)

    assert run(dir) == {"kept", "start-k3s"}

    assert %{copy?: true, replicas: ["0", "0"], annotations: [[_, _, _, _], [_, _, _, _]]} =
             server(dir)

    assert log(dir) =~ "output The API server did not answer within 5 minutes."
  end

  test "says k3s is down when it does not start after a step failed before the copy was whole",
       %{dir: dir} do
    File.write!(Path.join([dir, "bin", "cp"]), ~S"""
    #!/bin/sh
    case "$*" in */copy) echo "cp: No space left on device"; exit 1 ;; esac
    exec /bin/cp "$@"
    """)

    File.chmod!(Path.join([dir, "bin", "cp"]), 0o755)
    File.write!(Path.join(dir, "broken"), "1\n")

    assert run(dir) == {"down", "copy"}
    assert %{k3s: "inactive", disk_ca: "ca-old", replicas: ["0", "0"]} = server(dir)
    assert log(dir) =~ "output cp: No space left on device"
  end

  test "says the undo did not finish when EHOS cannot be scaled back", %{dir: dir} do
    File.write!(Path.join(dir, "fail"), "k3s token rotate\n")

    wrap(dir, "k3s", ~S"""
    case "$*" in *'"spec":{"replicas":1}'*) echo "Error from server (Forbidden)"; exit 1 ;; esac
    """)

    assert run(dir) == {"unclean", "scale-up"}
    assert %{disk_ca: "ca-old", token: "K10abc::server:old", replicas: ["0", "0"]} = server(dir)
  end

  test "stops, and changes nothing, when the disk has no room for the copy", %{dir: dir} do
    File.write!(Path.join(dir, "df"), "10\n")

    assert run(dir) == {"failed", "space"}
    assert server(dir) == unchanged()
    assert calls(dir, "k3s kubectl --request-timeout=30s patch") == []
  end

  test "scales EHOS back, and changes nothing else, when k3s does not stop", %{dir: dir} do
    File.write!(Path.join(dir, "fail"), "systemctl stop\n")

    assert run(dir) == {"stopped", "stop-k3s"}
    assert server(dir) == unchanged()
  end

  test "undoes the step when a pod of EHOS is still there after 5 minutes", %{dir: dir} do
    # Each request for the pods takes 14 seconds, or its whole time limit when that is shorter.
    wrap(dir, "k3s", ~S"""
    case "$*" in *"patch deployment ehos-operator"*) trap 'echo 1 >"$F/deploy/ehos-operator/pods"' EXIT ;; esac
    case "$*" in "kubectl --request-timeout="*"s get pods "*)
      l=${2#--request-timeout=}; l=${l%s}; if [ "$l" -gt 14 ]; then l=14; fi
      t=$(cat "$F/clock" 2>/dev/null || echo 1000000); echo $((t + l)) >"$F/clock" ;;
    esac
    """)

    assert run(dir) == {"stopped", "scale-down"}
    assert server(dir) == unchanged()
    assert log(dir) =~ "output A pod of EHOS is still there after 5 minutes, or kubectl failed."

    # Each request for the pods, the second of a try too, gets no more than the time left: the
    # wait ends at 5 minutes.
    assert File.read!(Path.join(dir, "clock")) |> String.trim() == "1000300"
  end

  test "refuses to record more than 10 replicas, and changes nothing", %{dir: dir} do
    File.write!(Path.join([dir, "deploy", "ehos-operator", "replicas"]), "12\n")

    assert run(dir) == {"stopped", "scale-down"}
    assert %{replicas: ["1", "12"], annotations: [[], []], copy?: false} = server(dir)
    assert log(dir) =~ "output The Deployment ehos-operator has 12 replicas."
  end

  test "reads only its own annotations, not another's value that names one", %{dir: dir} do
    annotate(dir, "ehos-governance", [
      "example.com/note=#{@annotation}replicas=7 #{@annotation}client-ca=1"
    ])

    assert run(dir) == {"finished", "-"}
    assert %{disk_ca: "ca-1", replicas: ["1", "1"]} = server(dir)
    assert %{annotations: [["example.com/note=" <> _note], []]} = server(dir)
  end

  test "deletes a folder of the new CA that a copy deleted in part left", %{dir: dir} do
    File.mkdir_p!(Path.join([dir, "ehosctl", "ca", "tls"]))
    File.write!(Path.join([dir, "ehosctl", "ca", "tls", "client-ca.key"]), "key-1\n")

    assert run(dir, "again") == {"cleared", "delete-copy"}
    refute File.exists?(Path.join([dir, "ehosctl", "ca"]))
  end

  test "keeps what the Kubernetes API answers out of the log", %{dir: dir} do
    wrap(dir, "k3s", ~S"""
    case "$*" in *"get --raw /api") echo '{"kind":"APIVersions"}'; exit 0 ;; esac
    """)

    assert run(dir) == {"finished", "-"}
    refute log(dir) =~ "APIVersions"
  end

  test "ends a wait for the API after 5 minutes by the clock, each try within the time left", %{
    dir: dir
  } do
    File.write!(Path.join(dir, "fail"), "k3s token rotate\n")

    wrap(dir, "systemctl", ~S"""
    if [ "$1" = start ]; then
      n=$(( $(cat "$F/starts" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$F/starts"
      if [ "$n" -ge 2 ]; then echo 1 >"$F/broken"; fi
    fi
    """)

    # A request to an API server that does not answer takes 14 seconds, or its whole time limit
    # when that is shorter.
    wrap(dir, "k3s", ~S"""
    case "$*" in "kubectl --request-timeout="*"s get --raw /readyz")
      if ! active; then
        l=${2#--request-timeout=}; l=${l%s}; if [ "$l" -gt 14 ]; then l=14; fi
        t=$(cat "$F/clock" 2>/dev/null || echo 1000000); echo $((t + l)) >"$F/clock"
      fi ;;
    esac
    """)

    assert run(dir) == {"kept", "start-k3s"}

    timeouts =
      for "k3s kubectl --request-timeout=" <> rest <-
            String.split(File.read!(Path.join(dir, "calls")), "\n"),
          String.ends_with?(rest, "get --raw /readyz"),
          do: rest |> String.split("s ", parts: 2) |> hd() |> String.to_integer()

    # Each try of the last wait takes 14 seconds and a pause of 5. The last try starts with 15
    # seconds left, its request may take them all, and the pause after it takes the 1 second left:
    # the wait ends at 5 minutes, and no pause runs past it.
    assert Enum.take(timeouts, -2) == [30, 15]
    assert File.read!(Path.join(dir, "clock")) |> String.trim() == "1000300"
  end

  test "refuses the scale down when someone scaled meanwhile, and leaves no annotation", %{
    dir: dir
  } do
    # ehos-operator goes from 1 to 11 replicas right after the process reads its count.
    wrap(dir, "k3s", ~S"""
    case "$*" in *"get deployment ehos-operator"*"jsonpath={.spec.replicas}"*)
      if [ ! -e "$F/read-once" ]; then : >"$F/read-once"; trap 'echo 11 >"$F/deploy/ehos-operator/replicas"' EXIT; fi ;;
    esac
    """)

    assert run(dir) == {"stopped", "scale-down"}
    assert %{replicas: ["1", "11"], annotations: [[], []], disk_ca: "ca-old"} = server(dir)
    assert log(dir) =~ "output Error from server (Conflict): Operation cannot be fulfilled"
  end

  test "takes a scale to zero whose answer was lost, and that applied, for done", %{
    dir: dir
  } do
    # The API server scales ehos-operator to zero, and kubectl gives up before the answer.
    wrap(dir, "k3s", ~S"""
    case "$*" in *"patch deployment ehos-operator"*'scaled":"true"'*)
      trap 'echo "Unable to connect to the server: context deadline exceeded"; exit 1' EXIT ;;
    esac
    """)

    assert run(dir) == {"finished", "-"}
    assert %{replicas: ["1", "1"], annotations: [[], []], disk_ca: "ca-1"} = server(dir)

    # The read after the timeout found the mark: no second patch to scale it down, then one to
    # scale it back.
    assert length(calls(dir, "k3s kubectl --request-timeout=30s patch deployment ehos-operator")) ==
             2
  end

  test "leaves a Deployment that someone scaled meanwhile at their count", %{
    dir: dir
  } do
    # ehos-operator goes to 11 replicas after its count is read.
    wrap(dir, "k3s", ~S"""
    case "$*" in
      *"get deployment ehos-operator"*"jsonpath={.spec.replicas}"*)
        if [ ! -e "$F/read-once" ]; then : >"$F/read-once"; trap 'echo 11 >"$F/deploy/ehos-operator/replicas"' EXIT; fi ;;
    esac
    """)

    assert run(dir) == {"stopped", "scale-down"}
    assert %{replicas: ["1", "11"], disk_ca: "ca-old"} = server(dir)
    assert log(dir) =~ "output Error from server (Conflict): Operation cannot be fulfilled"
  end

  test "never puts the copy back twice: a put back stopped before its check is checked again",
       %{dir: dir} do
    File.write!(Path.join(dir, "fail"), "k3s token rotate\n")

    # The process stops right after k3s starts on the copy put back, its second start.
    wrap(dir, "systemctl", ~S"""
    if [ "$1" = start ]; then
      n=$(( $(cat "$F/starts" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$F/starts"
      if [ "$n" -eq 2 ]; then trap ': >"$F/killed"; kill -9 "$(cat "$F/pid")"' EXIT; fi
    fi
    """)

    assert {"", :killed} = run(dir)
    assert File.exists?(Path.join([dir, "ehosctl", "restored"]))

    assert run(dir, "again") == {"undone", "-"}
    assert server(dir) == unchanged()
    # The copy's stop, then the put back's: no second put back.
    assert calls(dir, "systemctl stop") == [
             "systemctl stop k3s.service",
             "systemctl stop k3s.service"
           ]
  end

  test "reads a replica count from standard output alone, not with kubectl's warnings", %{
    dir: dir
  } do
    wrap(dir, "k3s", ~S"""
    case "$*" in *"jsonpath={.spec.replicas}"*) echo "Warning: apps/v1 is served" >&2 ;; esac
    """)

    assert run(dir) == {"finished", "-"}
    assert %{replicas: ["1", "1"], annotations: [[], []], disk_ca: "ca-1"} = server(dir)
  end

  test "marks the copy put back even when the folder moved aside cannot be deleted", %{
    dir: dir
  } do
    File.write!(Path.join(dir, "fail"), "k3s token rotate\n")

    File.write!(Path.join([dir, "bin", "rm"]), ~S"""
    #!/bin/sh
    # The put back's own removal: `repair`'s names two folders.
    if [ "$#" -eq 2 ]; then
      case "$2" in *.ehosctl-old) echo "rm: cannot remove: Operation not permitted"; exit 1 ;; esac
    fi
    exec /bin/rm "$@"
    """)

    File.chmod!(Path.join([dir, "bin", "rm"]), 0o755)

    assert run(dir) == {"kept", "put-back"}
    assert File.exists?(Path.join([dir, "ehosctl", "restored"]))
  end

  test "after a put back, a run again whose k3s does not start keeps the copy, and puts back nothing",
       %{dir: dir} do
    File.write!(Path.join(dir, "fail"), "k3s token rotate\n")

    wrap(dir, "systemctl", ~S"""
    if [ "$1" = start ]; then
      n=$(( $(cat "$F/starts" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$F/starts"
      if [ "$n" -eq 2 ]; then trap ': >"$F/killed"; kill -9 "$(cat "$F/pid")"' EXIT; fi
      if [ "$n" -ge 3 ]; then echo 1 >"$F/broken"; fi
    fi
    """)

    assert {"", :killed} = run(dir)
    File.write!(Path.join(dir, "k3s"), "inactive\n")

    assert run(dir, "again") == {"kept", "start-k3s"}
    assert %{copy?: true, disk_ca: "ca-old"} = server(dir)

    assert calls(dir, "systemctl stop") == [
             "systemctl stop k3s.service",
             "systemctl stop k3s.service"
           ]
  end

  test "after an undo that deleted its copy, a run again whose k3s does not start says k3s is down",
       %{dir: dir} do
    File.write!(Path.join(dir, "fail"), "k3s token rotate\n")

    assert run(dir) == {"undone", "rotate-token"}

    # As an undo that stopped after it deleted the copy and before it removed its mark and the
    # annotations leaves the server.
    File.write!(Path.join([dir, "ehosctl", "restored"]), "")
    annotate(dir, "ehos-governance", ["#{@annotation}replicas=1", "#{@annotation}client-ca=1"])
    File.write!(Path.join(dir, "k3s"), "inactive\n")
    File.write!(Path.join(dir, "broken"), "1\n")

    assert run(dir, "again") == {"down", "start-k3s"}
  end

  test "leaves a Deployment that someone scaled to zero meanwhile at zero", %{dir: dir} do
    # ehos-operator goes to 0 replicas after its count is read: its patch is refused, and leaves no
    # mark that scaling back would trust.
    wrap(dir, "k3s", ~S"""
    case "$*" in
      *"get deployment ehos-operator"*"jsonpath={.spec.replicas}"*)
        if [ ! -e "$F/read-once" ]; then
          : >"$F/read-once"
          trap 'echo 0 >"$F/deploy/ehos-operator/replicas"; echo 0 >"$F/deploy/ehos-operator/pods"' EXIT
        fi ;;
    esac
    """)

    assert run(dir) == {"stopped", "scale-down"}
    assert %{replicas: ["1", "0"], disk_ca: "ca-old"} = server(dir)
  end

  test "scales down a Deployment whose status changed meanwhile, at its new version", %{dir: dir} do
    # The Deployment controller writes the status of ehos-governance right before its patch.
    wrap(dir, "k3s", ~S"""
    case "$*" in *"patch deployment ehos-governance"*)
      if [ ! -e "$F/status-once" ]; then : >"$F/status-once"; echo "readyReplicas: 0" >"$F/deploy/ehos-governance/status"; fi ;;
    esac
    """)

    assert run(dir) == {"finished", "-"}
    assert %{replicas: ["1", "1"], disk_ca: "ca-1"} = server(dir)

    scale_downs =
      for call <- calls(dir, "k3s kubectl --request-timeout=30s patch deployment ehos-governance"),
          call =~ ~s(scaled":"true"),
          do: call

    assert length(scale_downs) == 2
  end

  test "stops when a Deployment was made again between its read and its patch", %{dir: dir} do
    # ehos-operator is deleted and made again, with the same count, after its count is read.
    wrap(dir, "k3s", ~S"""
    case "$*" in *"get deployment ehos-operator"*"jsonpath={.spec.replicas}"*)
      if [ ! -e "$F/read-once" ]; then
        : >"$F/read-once"
        trap 'echo 0a1b2c3d-9 >"$F/deploy/ehos-operator/uid"; echo "new" >"$F/deploy/ehos-operator/status"' EXIT
      fi ;;
    esac
    """)

    assert run(dir) == {"stopped", "scale-down"}
    assert %{replicas: ["1", "1"], annotations: [[], []], disk_ca: "ca-old"} = server(dir)
    assert log(dir) =~ "output The Deployment ehos-operator was made again meanwhile."
  end

  test "patches again at the same version when the answer was lost and the patch did not apply",
       %{dir: dir} do
    # The first scale-down patch of ehos-operator never reaches the API server.
    wrap(dir, "k3s", ~S"""
    case "$*" in *"patch deployment ehos-operator"*'scaled":"true"'*)
      if [ ! -e "$F/lost-once" ]; then
        : >"$F/lost-once"; echo "Unable to connect to the server: context deadline exceeded"; exit 1
      fi ;;
    esac
    """)

    assert run(dir) == {"finished", "-"}
    assert %{replicas: ["1", "1"], disk_ca: "ca-1"} = server(dir)

    versions =
      for call <- calls(dir, "k3s kubectl --request-timeout=30s patch deployment ehos-operator"),
          call =~ ~s(scaled":"true"),
          do: Regex.run(~r/"resourceVersion":"(\d+)"/, call, capture: :all_but_first)

    assert [same, same] = versions
  end

  test "leaves at zero a Deployment someone scaled to zero, when the process stops at the refusal",
       %{dir: dir} do
    # ehos-operator goes to 0 replicas after its count is read; the process is killed right after
    # its scale to zero was refused. The pattern for `--replicas=0` matches an earlier form that
    # scaled with `kubectl scale`, so that the test fails on it too.
    wrap(dir, "k3s", ~S"""
    case "$*" in
      *"get deployment ehos-operator"*"jsonpath={.spec.replicas}"*)
        if [ ! -e "$F/read-once" ]; then
          : >"$F/read-once"
          trap 'echo 0 >"$F/deploy/ehos-operator/replicas"; echo 0 >"$F/deploy/ehos-operator/pods"' EXIT
        fi ;;
      *"deployment ehos-operator --namespace ehos-system --replicas=0"* | *"patch deployment ehos-operator"*)
        trap ': >"$F/killed"; kill -9 "$(cat "$F/pid")"' EXIT ;;
    esac
    """)

    assert {"", :killed} = run(dir)

    assert run(dir, "again") == {"reverted", "-"}
    assert %{replicas: ["1", "0"], disk_ca: "ca-old"} = server(dir)
  end

  test "removes the rotation's mark in the write that scales a Deployment back", %{dir: dir} do
    # The finish stops right after it scaled ehos-governance back; someone then scales it to 0.
    File.write!(Path.join(dir, "kill"), ~s("spec":{"replicas":1}\n))
    assert {"", _killed} = run(dir)
    File.write!(Path.join([dir, "deploy", "ehos-governance", "replicas"]), "0\n")

    assert run(dir, "again") == {"finished", "-"}
    assert %{replicas: ["0", "1"], annotations: [[], []]} = server(dir)
  end

  test "stops before k3s does when a pod of EHOS runs again after the wait", %{dir: dir} do
    # The third read of the pods, the one right before the stop, finds one.
    wrap(dir, "k3s", ~S"""
    case "$*" in *"get pods"*)
      n=$(( $(cat "$F/pod-reads" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$F/pod-reads"
      if [ "$n" -eq 3 ]; then echo "pod/ehos-governance-2"; exit 0; fi ;;
    esac
    """)

    assert run(dir) == {"stopped", "stop-k3s"}
    assert server(dir) == unchanged()
    assert calls(dir, "systemctl stop") == []
  end

  test "scales back a Deployment whose lost scale-down applied late, before the cleanup ends", %{
    dir: dir
  } do
    # The scale-down patches of ehos-operator never answer, and none applies; then the first one
    # applies late, as the cleanup of the undo lists the annotations of ehos-operator.
    wrap(dir, "k3s", ~S"""
    case "$*" in
      *"patch deployment ehos-operator"*'scaled":"true"'*)
        echo "Unable to connect to the server: context deadline exceeded"; exit 1 ;;
      *"annotate deployment ehos-operator"*"--list"*)
        if grep -q "^step unannotate" "$F"/ehosctl/runs/*.log && [ ! -e "$F/late-once" ]; then
          : >"$F/late-once"
          echo 0 >"$F/deploy/ehos-operator/replicas"; echo 0 >"$F/deploy/ehos-operator/pods"
          printf '%s\n' ehos.empowered.house/client-ca-rotation-replicas=1 ehos.empowered.house/client-ca-rotation-client-ca=1 ehos.empowered.house/client-ca-rotation-scaled=true >>"$F/deploy/ehos-operator/annotations"
        fi ;;
    esac
    """)

    assert run(dir) == {"stopped", "scale-down"}
    assert %{replicas: ["1", "1"], annotations: [[], []], disk_ca: "ca-old"} = server(dir)
  end

  test "leaves no Deployment at the version a lost scale-down patch was sent at", %{dir: dir} do
    # The scale-down patches of ehos-operator never answer, and none applies before the process
    # ends; the first is kept, to apply late.
    wrap(dir, "k3s", ~S"""
    case "$*" in *"patch deployment ehos-operator"*'scaled":"true"'*)
      if [ -z "${LATE:-}" ]; then
        [ -e "$F/inflight" ] || printf '%s' "${10}" >"$F/inflight"
        echo "Unable to connect to the server: context deadline exceeded"; exit 1
      fi ;;
    esac
    """)

    assert run(dir) == {"stopped", "scale-down"}

    # The API server applies the lost patch now: it is refused, since the cleanup changed the
    # version it was sent at, and ehos-operator keeps its replica.
    {_output, _status} =
      System.cmd(
        Path.join([dir, "bin", "k3s"]),
        [
          "kubectl",
          "--request-timeout=30s",
          "patch",
          "deployment",
          "ehos-operator",
          "--namespace",
          "ehos-system",
          "--type=merge",
          "-p",
          File.read!(Path.join(dir, "inflight"))
        ],
        env: [{"FAKE", dir}, {"LATE", "1"}, {"PATH", Path.join(dir, "bin") <> ":/usr/bin:/bin"}],
        stderr_to_stdout: true
      )

    assert %{replicas: ["1", "1"], annotations: [[], []], disk_ca: "ca-old"} = server(dir)
  end

  test "scales back no Deployment made again between the reads of its version and its mark", %{
    dir: dir
  } do
    # After the checks, ehos-governance is made again at 0 replicas, without the rotation's mark,
    # right before scaling back reads its version: an earlier read of its mark is the old one's.
    wrap(dir, "k3s", ~S"""
    case "$*" in *"get deployment ehos-governance"*"metadata.uid"*)
      if grep -q "^step scale-up" "$F"/ehosctl/runs/*.log && [ ! -e "$F/made-once" ]; then
        : >"$F/made-once"
        echo 0a1b2c3d-9 >"$F/deploy/ehos-governance/uid"; echo 0 >"$F/deploy/ehos-governance/replicas"
        : >"$F/deploy/ehos-governance/annotations"
      fi ;;
    esac
    """)

    assert run(dir) == {"finished", "-"}
    assert %{replicas: ["0", "1"], annotations: [[], []]} = server(dir)
  end

  test "marks a copy found in place as put back, so that a run again never puts it back again",
       %{dir: dir} do
    File.write!(Path.join(dir, "kill"), "openssl req\n")
    assert {"", _killed} = run(dir)

    # As a put back that stopped after it moved the copy into place, before it wrote its mark.
    server = Path.join(dir, "server")
    File.rename!(server, server <> ".ehosctl-old")
    File.cp_r!(Path.join([dir, "ehosctl", "copy"]), server)
    File.write!(Path.join(dir, "k3s"), "inactive\n")

    assert run(dir, "again") == {"undone", "-"}
    assert server(dir) == unchanged()
    # The copy's stop alone: no put back.
    assert calls(dir, "systemctl stop") == ["systemctl stop k3s.service"]
  end

  test "never puts the copy back twice: after a put back that held, a run again cleans up", %{
    dir: dir
  } do
    File.write!(Path.join(dir, "fail"), "k3s token rotate\n")
    File.write!(Path.join(dir, "noscale"), "")

    wrap(dir, "k3s", ~S"""
    case "$*" in *'"spec":{"replicas":1}'*)
      if [ -e "$F/noscale" ]; then echo "Error from server (Forbidden)"; exit 1; fi ;;
    esac
    """)

    assert run(dir) == {"unclean", "scale-up"}
    assert File.exists?(Path.join([dir, "ehosctl", "restored"]))
    File.rm!(Path.join(dir, "noscale"))

    assert run(dir, "again") == {"undone", "-"}
    assert server(dir) == unchanged()
    # The copy's stop, then the put back's: no second put back.
    assert calls(dir, "systemctl stop") == [
             "systemctl stop k3s.service",
             "systemctl stop k3s.service"
           ]
  end

  describe "a read of the cluster that fails" do
    test "after the checks, is tried again, and EHOS goes back to its counts", %{dir: dir} do
      # The first list of the annotations of ehos-governance after the checks fails.
      wrap(dir, "k3s", ~S"""
      case "$*" in *"get --raw /api"*) : >"$F/armed" ;; esac
      case "$*" in *"annotate deployment ehos-governance"*"--list"*)
        if [ -e "$F/armed" ]; then rm "$F/armed"; echo "Error from server (ServiceUnavailable)"; exit 1; fi ;;
      esac
      """)

      assert run(dir) == {"finished", "-"}
      assert %{replicas: ["1", "1"], annotations: [[], []], disk_ca: "ca-1"} = server(dir)
    end

    test "while EHOS scales down, stops the rotation, and is not read as no pod left", %{dir: dir} do
      File.write!(Path.join(dir, "fail"), "kubectl --request-timeout=30s get pods\n")

      assert run(dir) == {"stopped", "scale-down"}
      assert server(dir) == unchanged()
      assert log(dir) =~ "output injected failure of k3s kubectl --request-timeout=30s get pods"
    end

    test "on a run again, decides nothing and rotates nothing", %{dir: dir} do
      File.write!(Path.join(dir, "kill"), "systemctl stop k3s.service\n")
      assert {"", _killed} = run(dir)

      # The run again reads the annotations once, then each later list of them fails.
      wrap(dir, "k3s", ~S"""
      case "$*" in *"annotate deployment"*"--list"*)
        n=$(( $(cat "$F/lists" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$F/lists"
        if [ "$n" -gt 2 ]; then echo "Error from server (ServiceUnavailable)"; exit 1; fi ;;
      esac
      """)

      assert run(dir, "again") == {"failed", "read"}
      assert %{disk_ca: "ca-old", token: "K10abc::server:old"} = server(dir)
      assert log(dir) =~ "output Error from server (ServiceUnavailable)"
      assert calls(dir, "k3s token rotate") == []
    end
  end

  describe "run again" do
    test "after a process killed during the checks, finishes with the new CA", %{dir: dir} do
      File.write!(Path.join(dir, "kill"), "k3s kubectl --request-timeout=30s get nodes\n")
      assert {"", _killed} = run(dir)

      assert run(dir, "again") == {"finished", "-"}
      assert %{disk_ca: "ca-1", token: "token1", copy?: false} = server(dir)
      assert %{replicas: ["1", "1"], annotations: [[], []]} = server(dir)
      assert calls(dir, "k3s token rotate") == ["k3s token rotate"]
    end

    test "after a process killed between the two rotations, rotates the token and finishes", %{
      dir: dir
    } do
      File.write!(Path.join(dir, "kill"), "systemctl restart k3s.service\n")
      assert {"", _killed} = run(dir)
      assert %{disk_ca: "ca-1", token: "K10abc::server:old"} = server(dir)

      assert run(dir, "again") == {"finished", "-"}

      assert server(dir) == %{
               k3s: "active",
               disk_ca: "ca-1",
               datastore_ca: "ca-1",
               token: "token1",
               replicas: ["1", "1"],
               annotations: [[], []],
               copy?: false
             }
    end

    test "after a process killed before rotate-ca, undoes to the old CA", %{dir: dir} do
      File.write!(Path.join(dir, "kill"), "openssl req\n")
      assert {"", _killed} = run(dir)

      assert run(dir, "again") == {"undone", "-"}
      assert server(dir) == unchanged()
    end

    test "after rotate-ca and before its restart, undoes the CA in the datastore", %{dir: dir} do
      File.write!(Path.join(dir, "kill"), "k3s certificate rotate-ca\n")
      assert {"", _killed} = run(dir)
      assert %{disk_ca: "ca-old", datastore_ca: "ca-1"} = server(dir)

      assert run(dir, "again") == {"undone", "-"}
      assert server(dir) == unchanged()
    end

    test "after a process killed with k3s stopped for the copy, starts k3s and ends it", %{
      dir: dir
    } do
      File.write!(Path.join(dir, "kill"), "systemctl stop k3s.service\n")
      assert {"", _killed} = run(dir)
      assert %{k3s: "inactive", replicas: ["0", "0"]} = server(dir)

      assert run(dir, "again") == {"reverted", "-"}
      assert server(dir) == unchanged()
    end

    test "after the checks passed, never puts the copy back, even when k3s does not start", %{
      dir: dir
    } do
      File.write!(
        Path.join(dir, "kill"),
        ~s("spec":{"replicas":1}\n)
      )

      assert {"", _killed} = run(dir)
      File.write!(Path.join(dir, "k3s"), "inactive\n")
      File.write!(Path.join(dir, "broken"), "1\n")

      assert run(dir, "again") == {"stalled", "start-k3s"}
      assert %{disk_ca: "ca-1", token: "token1", copy?: true} = server(dir)
      assert calls(dir, "systemctl stop") == ["systemctl stop k3s.service"]

      # Once k3s starts, a run again finishes.
      assert run(dir, "again") == {"finished", "-"}

      assert %{disk_ca: "ca-1", replicas: ["1", "1"], annotations: [[], []], copy?: false} =
               server(dir)
    end

    test "with the CA changed, the token not, and the copy gone, only scales EHOS back", %{
      dir: dir
    } do
      File.write!(Path.join(dir, "kill"), "systemctl restart k3s.service\n")
      assert {"", _killed} = run(dir)
      File.rm_rf!(Path.join([dir, "ehosctl", "copy"]))
      File.rm!(Path.join([dir, "ehosctl", "copy.complete"]))

      assert run(dir, "again") == {"partial", "-"}

      assert server(dir) == %{
               k3s: "active",
               disk_ca: "ca-1",
               datastore_ca: "ca-1",
               token: "K10abc::server:old",
               replicas: ["1", "1"],
               annotations: [[], []],
               copy?: false
             }

      assert calls(dir, "k3s token rotate") == []

      # A run again with nothing begun starts nothing; a new start rotates both.
      assert run(dir, "again") == {"cleared", "-"}
      assert run(dir) == {"finished", "-"}
      assert %{disk_ca: "ca-2", token: "token1"} = server(dir)
    end

    test "says the rotation is not finished when EHOS cannot be scaled back after a partial one",
         %{dir: dir} do
      File.write!(Path.join(dir, "kill"), "systemctl restart k3s.service\n")
      assert {"", _killed} = run(dir)
      File.rm_rf!(Path.join([dir, "ehosctl", "copy"]))
      File.rm!(Path.join([dir, "ehosctl", "copy.complete"]))

      wrap(dir, "k3s", ~S"""
      case "$*" in *'"spec":{"replicas":1}'*) echo "Error from server (Forbidden)"; exit 1 ;; esac
      """)

      assert run(dir, "again") == {"unfinished", "scale-up"}
      assert %{disk_ca: "ca-1", token: "K10abc::server:old"} = server(dir)
    end

    test "refuses a replica count outside 0 to 10, and changes nothing", %{dir: dir} do
      annotate(dir, "ehos-governance", ["#{@annotation}replicas=11", "#{@annotation}client-ca=1"])

      assert run(dir, "again") == {"refused", "-"}
      assert %{annotations: [[_, _], []], disk_ca: "ca-old"} = server(dir)
    end

    test "deletes a copy that no annotation records, and never puts it back", %{dir: dir} do
      File.cp_r!(Path.join(dir, "server"), Path.join([dir, "ehosctl", "copy"]))
      File.write!(Path.join([dir, "ehosctl", "copy.complete"]), "")

      assert run(dir, "again") == {"cleared", "delete-copy"}
      assert server(dir) == unchanged()
      assert calls(dir, "systemctl stop") == []
    end

    test "after a process killed right after the cleanup's write of its closing mark, finishes",
         %{dir: dir} do
      # The removal of the annotations of ehos-operator applies, but its answer is lost; the retry
      # finds ehos-governance with none left, writes the closing mark on it, and is killed.
      wrap(dir, "k3s", ~S"""
      case "$*" in *"annotate deployment ehos-operator"*"client-ca-rotation-replicas-"*)
        if [ ! -e "$F/lost-once" ]; then
          : >"$F/lost-once"; : >"$F/deploy/ehos-operator/annotations"; written ehos-operator
          echo "Unable to connect to the server: context deadline exceeded"; exit 1
        fi ;;
      esac
      """)

      File.write!(Path.join(dir, "kill"), "client-ca-rotation-closed=\n")
      assert {"", _killed} = run(dir)

      assert %{annotations: [["#{@annotation}closed=0123456789abcdef"], []], disk_ca: "ca-1"} =
               server(dir)

      assert run(dir, "again") == {"finished", "-"}

      assert server(dir) == %{
               k3s: "active",
               disk_ca: "ca-1",
               datastore_ca: "ca-1",
               token: "token1",
               replicas: ["1", "1"],
               annotations: [[], []],
               copy?: false
             }
    end

    test "with the closing mark alone and no checks passed, removes it and says what is left",
         %{dir: dir} do
      annotate(dir, "ehos-operator", ["#{@annotation}closed=00000000000000aa"])

      assert run(dir, "again") == {"ended", "-"}
      assert server(dir) == unchanged()
    end

    test "with nothing begun, ends without a rotation", %{dir: dir} do
      assert run(dir, "again") == {"cleared", "-"}
      assert server(dir) == unchanged()
    end

    test "completes a put back that stopped between its two renames", %{dir: dir} do
      File.write!(Path.join(dir, "kill"), "openssl req\n")
      assert {"", _killed} = run(dir)

      server = Path.join(dir, "server")
      File.rename!(server, server <> ".ehosctl-old")
      File.cp_r!(Path.join([dir, "ehosctl", "copy"]), server <> ".ehosctl-new")
      File.write!(Path.join(dir, "k3s"), "inactive\n")

      assert run(dir, "again") == {"undone", "-"}
      assert server(dir) == unchanged()
      refute File.exists?(server <> ".ehosctl-new")
      refute File.exists?(server <> ".ehosctl-old")
    end
  end

  # Runs `script` before the program `name` does what it does.
  defp wrap(dir, name, script) do
    path = Path.join([dir, "bin", name])
    File.write!(path, String.replace(File.read!(path), @prelude, @prelude <> script))
  end

  defp annotate(dir, deployment, lines),
    do:
      File.write!(
        Path.join([dir, "deploy", deployment, "annotations"]),
        Enum.map_join(lines, &(&1 <> "\n"))
      )

  defp unchanged do
    %{
      k3s: "active",
      disk_ca: "ca-old",
      datastore_ca: "ca-old",
      token: "K10abc::server:old",
      replicas: ["1", "1"],
      annotations: [[], []],
      copy?: false
    }
  end

  # Runs the process as its systemd unit would, and returns its result's outcome and step, or
  # nothing when it was killed.
  defp run(dir, mode \\ "start") do
    File.rm(Path.join([dir, "ehosctl", "runs", "0123456789abcdef.result"]))
    script = Path.join([dir, "ehosctl", "process-0123456789abcdef.sh"])
    File.write!(script, ClientCa.process_script())

    {output, status} =
      System.cmd(
        "/bin/sh",
        [
          "-c",
          ~S(echo $$ >"$FAKE/pid"; exec /bin/sh "$0" "$@"),
          script,
          "0123456789abcdef",
          mode,
          Path.join(dir, "ehosctl"),
          Path.join(dir, "server")
        ],
        env: [{"FAKE", dir}, {"PATH", Path.join(dir, "bin") <> ":/usr/bin:/bin"}],
        stderr_to_stdout: true
      )

    # What the process printed, as its systemd unit's journal keeps it.
    File.write!(Path.join(dir, "journal"), output, [:append])

    case File.read(Path.join([dir, "ehosctl", "runs", "0123456789abcdef.result"])) do
      {:ok, result} ->
        ["0123456789abcdef", outcome, step] = result |> String.trim() |> String.split(" ")
        {outcome, step}

      {:error, :enoent} ->
        killed(dir, output, status)
    end
  end

  # A process that ended with no result was killed by a test, as `kill` asked: else it failed.
  defp killed(dir, output, status) do
    case File.rm(Path.join(dir, "killed")) do
      :ok ->
        {"", :killed}

      {:error, :enoent} ->
        flunk("The process ended with no result and no kill, exit status #{status}:\n" <> output)
    end
  end

  defp server(dir) do
    read = &(dir |> Path.join(&1) |> File.read!() |> String.trim())
    deployments = ["ehos-governance", "ehos-operator"]

    %{
      k3s: read.("k3s"),
      disk_ca: read.("server/tls/client-ca.crt"),
      datastore_ca: read.("server/db/client-ca"),
      token: read.("server/token"),
      replicas: Enum.map(deployments, &read.("deploy/#{&1}/replicas")),
      annotations:
        Enum.map(
          deployments,
          &(read.("deploy/#{&1}/annotations") |> String.split("\n", trim: true))
        ),
      copy?: File.exists?(Path.join([dir, "ehosctl", "copy"]))
    }
  end

  defp journal(dir), do: File.read!(Path.join(dir, "journal"))

  defp grep_path, do: Enum.find(["/usr/bin/grep", "/bin/grep"], &File.exists?/1)

  # The log of the runs, which all have the same id in these tests, in order.
  defp log(dir), do: File.read!(Path.join([dir, "ehosctl", "runs", "0123456789abcdef.log"]))

  defp steps(dir) do
    for "step " <> step <- String.split(log(dir), "\n"), do: step
  end

  defp calls(dir, prefix) do
    dir
    |> Path.join("calls")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, prefix))
  end
end
