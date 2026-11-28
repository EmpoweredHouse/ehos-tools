defmodule EhosPlatform.Server.ClientCaScriptsTest do
  # The scripts that read the server, start the process of the rotation and follow it (eh-os D-199),
  # run with `sh` in the test's folder, where `/var/lib/` stands for the server's, against programs that
  # stand in for sudo, flock, timeout, systemctl, systemd-run and k3s. `flock` holds its lock as a
  # directory, so that a program called under the lock can try to take it.
  use ExUnit.Case, async: true

  alias EhosPlatform.Server.ClientCa

  @moduletag :tmp_dir

  @programs %{
    "sudo" => ~S"""
    if [ "$1" = -n ]; then shift; fi
    exec "$@"
    """,
    "flock" => ~S"""
    nonblock= code=1
    while :; do
      case "$1" in
        -n) nonblock=1; shift ;;
        -E) code=$2; shift 2 ;;
        -w) shift 2 ;;
        *) break ;;
      esac
    done
    lock=$1
    shift
    mkdir "$lock.held" 2>/dev/null || { if [ -n "$nonblock" ]; then exit "$code"; fi; exit 1; }
    "$@"
    r=$?
    rmdir "$lock.held"
    exit "$r"
    """,
    # Ends the program, whatever time it is given, with the status of the real one: after 5 seconds,
    # long enough for a loaded machine to answer, or after 1 in a test of a call that `hang` names.
    "timeout" => ~S"""
    shift
    t=5
    if [ -e "$FAKE/hang" ]; then t=1; fi
    "$@" &
    p=$!
    (sleep "$t"; kill "$p") >/dev/null 2>&1 &
    w=$!
    wait "$p" 2>/dev/null
    r=$?
    kill "$w" 2>/dev/null
    if [ "$r" -gt 128 ]; then exit 124; fi
    exit "$r"
    """,
    # The unit of the rotation runs when `unit` says `active`. The call that `hang` names does not
    # answer. `race` runs once, right after the first of the status's two reads, the unit's or
    # `current`'s, whichever comes first.
    "systemctl" => ~S"""
    if [ "$(/bin/cat "$FAKE/hang" 2>/dev/null)" = "$*" ]; then exec sleep 30; fi
    case "$*" in
      "is-active k3s.service") echo active ;;
      "is-active --quiet ehosctl-client-ca.service") [ "$(/bin/cat "$FAKE/unit" 2>/dev/null)" = active ] ;;
      "is-active ehosctl-client-ca.service")
        s=$(/bin/cat "$FAKE/unit" 2>/dev/null || echo inactive)
        echo "$s"
        if [ -e "$FAKE/race" ]; then mv "$FAKE/race" "$FAKE/race.run"; sh "$FAKE/race.run"; fi
        [ "$s" = active ] ;;
      *) echo "unknown systemctl call: $*"; exit 1 ;;
    esac
    """,
    "cat" => ~S"""
    /bin/cat "$@"
    r=$?
    case "$*" in */current)
      if [ -e "$FAKE/race" ]; then mv "$FAKE/race" "$FAKE/race.run"; sh "$FAKE/race.run"; fi ;;
    esac
    exit "$r"
    """,
    "systemd-run" => ~S"""
    printf '%s\n' "$*" >>"$FAKE/systemd-run"
    """,
    "k3s" => ~S"""
    printf '%s\n' '{"items": []}'
    """
  }

  setup %{tmp_dir: dir} do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)

    for {name, body} <- @programs do
      path = Path.join(bin, name)
      File.write!(path, "#!/bin/sh\n" <> body)
      File.chmod!(path, 0o755)
    end

    %{dir: dir, state: Path.join(dir, "var/lib/ehosctl/client-ca")}
  end

  describe "the status" do
    test "reads the process and the last run together, under the lock of a start", %{
      dir: dir,
      state: state
    } do
      File.mkdir_p!(state)
      File.write!(Path.join(state, "current"), "00000000000000aa\n")
      File.write!(Path.join(dir, "unit"), "inactive\n")

      # Run aa has ended. Between the two reads, another start names its run bb and starts the unit:
      # read apart, the status would say that the unit runs, with the run that ended, or that it
      # does not, with the run that runs.
      File.write!(Path.join(dir, "race"), """
      flock -n "#{state}/start.lock" sh -c 'echo 00000000000000bb >"$1/current"; echo active >"$2/unit"' sh "#{state}" "#{dir}"
      """)

      assert dir |> run(ClientCa.status_script()) |> ClientCa.parse_status() ==
               {:ok,
                %{
                  k3s?: true,
                  process?: false,
                  copy: :none,
                  last: "00000000000000aa",
                  deployments: []
                }}
    end

    test "fails, and lets the lock of a start go, when systemd does not answer under it", %{
      dir: dir,
      state: state
    } do
      File.mkdir_p!(state)
      File.write!(Path.join(state, "current"), "00000000000000aa\n")
      File.write!(Path.join(dir, "hang"), "is-active ehosctl-client-ca.service")

      assert {"", 3} = sh(dir, ClientCa.status_script(), "")
      refute File.exists?(Path.join(state, "start.lock.held"))
    end

    test "fails when systemd does not answer on a server where no rotation ran", %{dir: dir} do
      File.write!(Path.join(dir, "hang"), "is-active ehosctl-client-ca.service")

      assert {"", 3} = sh(dir, ClientCa.status_script(), "")
    end

    test "fails when systemd does not say whether k3s runs", %{dir: dir} do
      File.write!(Path.join(dir, "hang"), "is-active k3s.service")

      assert {"", 3} = sh(dir, ClientCa.status_script(), "")
    end

    test "reads a server where no rotation ran", %{dir: dir} do
      assert dir |> run(ClientCa.status_script()) |> ClientCa.parse_status() ==
               {:ok, %{k3s?: true, process?: false, copy: :none, last: "-", deployments: []}}
    end
  end

  describe "the start" do
    test "starts the process under a unit of its own, and names its run the last one", %{
      dir: dir,
      state: state
    } do
      run(dir, ClientCa.start_script(), start("start", "the script\n"))

      assert File.read!(Path.join(state, "current")) == "00000000000000cc\n"
      assert File.read!(Path.join(state, "process-00000000000000cc.sh")) == "the script\n"

      assert File.read!(Path.join(dir, "systemd-run")) ==
               "--unit=ehosctl-client-ca --collect --quiet --property=Type=exec /bin/sh " <>
                 "#{state}/process-00000000000000cc.sh 00000000000000cc start #{state} " <>
                 "#{dir}/var/lib/rancher/k3s/server\n"
    end

    test "starts nothing, and names no run the last one, when the script did not arrive whole", %{
      dir: dir,
      state: state
    } do
      File.mkdir_p!(state)
      File.write!(Path.join(state, "current"), "00000000000000aa\n")

      # The size says 24 bytes; SSH stopped after the first line.
      input = "00000000000000cc\nagain\n-\n24\nthe first line\n"

      assert {"", 6} = sh(dir, ClientCa.start_script(), input)

      assert File.read!(Path.join(state, "current")) == "00000000000000aa\n"
      assert state |> File.ls!() |> Enum.sort() == ["current", "runs"]
      refute File.exists?(Path.join(dir, "systemd-run"))
    end

    test "starts nothing, and lets its lock go, when systemd does not say whether the unit runs",
         %{
           dir: dir,
           state: state
         } do
      File.mkdir_p!(state)
      File.write!(Path.join(state, "current"), "00000000000000aa\n")
      File.write!(Path.join(dir, "hang"), "is-active --quiet ehosctl-client-ca.service")

      assert {"", 3} = sh(dir, ClientCa.start_script(), start("again", "the script\n"))

      assert File.read!(Path.join(state, "current")) == "00000000000000aa\n"
      refute File.exists?(Path.join(state, "start.lock.held"))
      refute File.exists?(Path.join(dir, "systemd-run"))
    end

    test "keeps each run of the last hour past the last 5, its log and result together, by the newer",
         %{dir: dir, state: state} do
      # Runs 03 to 08 ran in the last hour; run 02 logged 90 minutes ago and wrote its result 55
      # minutes ago, so 6 runs are newer than it; run 01 ended hours ago.
      ran(state, id(1), log: 300, result: 300)
      ran(state, id(2), log: 90, result: 55)
      for n <- 3..8, do: ran(state, id(n), log: 50 - 5 * n, result: 50 - 5 * n)
      File.write!(Path.join(state, "current"), id(8) <> "\n")

      run(dir, ClientCa.start_script(), start("again", "the script\n"))

      assert runs(state) == Enum.flat_map(2..8, &["#{id(&1)}.log", "#{id(&1)}.result"])
    end

    test "keeps the files of the last 5 runs and of each run of the last hour, and deletes the rest",
         %{dir: dir, state: state} do
      # Runs 01 to 07 ended hours ago, 01 first; runs 08 and 09 ran in the last hour.
      for n <- 1..7, do: ran(state, id(n), log: 400 - 30 * n, result: 400 - 30 * n)
      ran(state, id(8), log: 50, result: 50)
      ran(state, id(9), log: 10, result: 5)
      File.write!(Path.join(state, "runs/#{id(9)}.result.new"), "")
      File.write!(Path.join(state, "current"), id(9) <> "\n")

      run(dir, ClientCa.start_script(), start("again", "the script\n"))

      assert runs(state) ==
               Enum.flat_map(5..9, &["#{id(&1)}.log", "#{id(&1)}.result"]) ++
                 ["#{id(9)}.result.new"]
    end

    test "keeps the run before, however old it is", %{dir: dir, state: state} do
      for n <- 1..6, do: ran(state, id(n), log: 400 - 30 * n, result: 400 - 30 * n)
      File.write!(Path.join(state, "current"), id(1) <> "\n")

      run(dir, ClientCa.start_script(), start("again", "the script\n"))

      assert runs(state) == Enum.flat_map(1..6, &["#{id(&1)}.log", "#{id(&1)}.result"])
    end
  end

  describe "the follow" do
    test "reads the run, whether the process runs, its result and the rest of its log", %{
      dir: dir,
      state: state
    } do
      ran(state, id(1), log: 1, result: 1)
      File.write!(Path.join(state, "runs/#{id(1)}.log"), "run #{id(1)}\nstep one\n")
      File.write!(Path.join(state, "runs/#{id(1)}.result"), "#{id(1)} finished -\n")

      assert run(dir, ClientCa.follow_script(), "4\n#{id(1)}\n") ==
               "run #{id(1)}\nprocess inactive\nresult #{id(1)} finished -\n--- log ---\n" <>
                 "#{id(1)}\nstep one\n"
    end

    test "fails when systemd does not say whether the process runs", %{dir: dir} do
      File.write!(Path.join(dir, "hang"), "is-active ehosctl-client-ca.service")

      assert sh(dir, ClientCa.follow_script(), "0\n-\n") == {"run -\n", 3}
    end
  end

  # Runs `script` as the server would, with `/var/lib/` in the test's folder, and `input` on its
  # standard input; returns what it printed.
  defp run(dir, script, input \\ "") do
    {output, 0} = sh(dir, script, input)
    output
  end

  # Runs `script` as `run/3` does; returns what it printed and its exit status.
  defp sh(dir, script, input) do
    path = Path.join(dir, "script.sh")
    File.write!(path, String.replace(script, "/var/lib/", Path.join(dir, "var/lib") <> "/"))
    File.write!(Path.join(dir, "input"), input)

    System.cmd("/bin/sh", ["-c", ~S(exec /bin/sh "$0" <"$1"), path, Path.join(dir, "input")],
      env: [{"FAKE", dir}, {"PATH", Path.join(dir, "bin") <> ":/usr/bin:/bin"}],
      stderr_to_stdout: true
    )
  end

  # The input of a start of run cc, in `mode`, after no run that ehosctl read, of `script`.
  defp start(mode, script),
    do: "00000000000000cc\n#{mode}\n-\n#{byte_size(script)}\n" <> script

  # A run whose log and result were last written the given numbers of minutes ago.
  defp ran(state, id, ages) do
    runs = Path.join(state, "runs")
    File.mkdir_p!(runs)

    for {kind, minutes} <- ages do
      path = Path.join(runs, "#{id}.#{kind}")
      File.write!(path, "")
      File.touch!(path, System.os_time(:second) - minutes * 60)
    end
  end

  defp runs(state), do: state |> Path.join("runs") |> File.ls!() |> Enum.sort()

  defp id(n), do: "00000000000000" <> String.pad_leading(Integer.to_string(n), 2, "0")
end
