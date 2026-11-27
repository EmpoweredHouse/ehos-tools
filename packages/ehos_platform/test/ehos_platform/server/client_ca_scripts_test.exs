defmodule EhosPlatform.Server.ClientCaScriptsTest do
  # The scripts that read the server and start the process of the rotation (eh-os D-199), run with
  # `sh` in the test's folder, where `/var/lib/` stands for the server's, against programs that
  # stand in for sudo, flock, systemctl, systemd-run and k3s. `flock` holds its lock as a
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
    # The unit of the rotation runs when `unit` says `active`; `race` runs when the status reads it.
    "systemctl" => ~S"""
    case "$*" in
      "is-active k3s.service") echo active ;;
      "is-active --quiet ehosctl-client-ca.service") [ "$(cat "$FAKE/unit" 2>/dev/null)" = active ] ;;
      "is-active ehosctl-client-ca.service")
        s=$(cat "$FAKE/unit" 2>/dev/null || echo inactive)
        if [ -e "$FAKE/race" ]; then sh "$FAKE/race"; fi
        echo "$s"
        [ "$s" = active ] ;;
      *) echo "unknown systemctl call: $*"; exit 1 ;;
    esac
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
      File.write!(Path.join(dir, "unit"), "active\n")

      # Right as the status reads the unit, its run ends, and another start names its own run.
      File.write!(Path.join(dir, "race"), """
      flock -n "#{state}/start.lock" sh -c 'echo 00000000000000bb >"$1/current"' sh "#{state}"
      """)

      assert {:ok, %{process?: true, last: "00000000000000aa"}} =
               dir |> run(ClientCa.status_script()) |> ClientCa.parse_status()
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
      run(dir, ClientCa.start_script(), "00000000000000cc\nstart\n-\nthe script\n")

      assert File.read!(Path.join(state, "current")) == "00000000000000cc\n"
      assert File.read!(Path.join(state, "process-00000000000000cc.sh")) == "the script\n"

      assert File.read!(Path.join(dir, "systemd-run")) ==
               "--unit=ehosctl-client-ca --collect --quiet --property=Type=exec /bin/sh " <>
                 "#{state}/process-00000000000000cc.sh 00000000000000cc start #{state} " <>
                 "#{dir}/var/lib/rancher/k3s/server\n"
    end

    test "keeps the log and the result of a run together, by the age of the newer one", %{
      dir: dir,
      state: state
    } do
      ran(state, "00000000000000aa", log: 90, result: 10)
      ran(state, "00000000000000bb", log: 5, result: 5)
      File.write!(Path.join(state, "current"), "00000000000000bb\n")

      run(dir, ClientCa.start_script(), "00000000000000cc\nagain\n-\nthe script\n")

      assert runs(state) == [
               "00000000000000aa.log",
               "00000000000000aa.result",
               "00000000000000bb.log",
               "00000000000000bb.result"
             ]
    end

    test "keeps the files of the last 5 runs and of each run of the last hour, and deletes the rest",
         %{dir: dir, state: state} do
      # Runs 01 to 07 ended hours ago, 01 first; runs 08 and 09 ran in the last hour.
      for n <- 1..7, do: ran(state, id(n), log: 400 - 30 * n, result: 400 - 30 * n)
      ran(state, id(8), log: 50, result: 50)
      ran(state, id(9), log: 10, result: 5)
      File.write!(Path.join(state, "runs/#{id(9)}.result.new"), "")
      File.write!(Path.join(state, "current"), id(9) <> "\n")

      run(dir, ClientCa.start_script(), "00000000000000cc\nagain\n-\nthe script\n")

      assert runs(state) ==
               Enum.flat_map(5..9, &["#{id(&1)}.log", "#{id(&1)}.result"]) ++
                 ["#{id(9)}.result.new"]
    end

    test "keeps the run before, however old it is", %{dir: dir, state: state} do
      for n <- 1..6, do: ran(state, id(n), log: 400 - 30 * n, result: 400 - 30 * n)
      File.write!(Path.join(state, "current"), id(1) <> "\n")

      run(dir, ClientCa.start_script(), "00000000000000cc\nagain\n-\nthe script\n")

      assert runs(state) == Enum.flat_map(1..6, &["#{id(&1)}.log", "#{id(&1)}.result"])
    end
  end

  # Runs `script` as the server would, with `/var/lib/` in the test's folder, and `input` on its
  # standard input; returns what it printed.
  defp run(dir, script, input \\ "") do
    path = Path.join(dir, "script.sh")
    File.write!(path, String.replace(script, "/var/lib/", Path.join(dir, "var/lib") <> "/"))
    File.write!(Path.join(dir, "input"), input)

    {output, 0} =
      System.cmd("/bin/sh", ["-c", ~S(exec /bin/sh "$0" <"$1"), path, Path.join(dir, "input")],
        env: [{"FAKE", dir}, {"PATH", Path.join(dir, "bin") <> ":/usr/bin:/bin"}],
        stderr_to_stdout: true
      )

    output
  end

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
