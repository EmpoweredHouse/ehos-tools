defmodule Ehosctl.SessionFilesTest do
  use Ehosctl.Case, async: true

  import Bitwise

  alias Ehosctl.SessionFiles

  doctest Ehosctl.SessionFiles

  @moduletag :tmp_dir

  @ends ~U[2026-10-28 13:00:00Z]
  @id "6f1c2a9e-5b7d-4c1e-9a2f-3d4e5f6a7b8c"

  test "writes the password file and the data CA, readable only by the person", %{tmp_dir: tmp} do
    dir = SessionFiles.dir(tmp)
    prefix = Path.join(dir, "#{System.pid()}-#{DateTime.to_unix(@ends)}-#{@id}")

    assert SessionFiles.write(dir, session()) ==
             {:ok, %SessionFiles{passfile: prefix <> ".pgpass", root_cert: prefix <> ".crt"}}

    assert File.read!(prefix <> ".pgpass") ==
             "ehos-ledger-rw.ehos-data.svc:5432:apps:ehos_s_abc:the-password\n"

    assert File.read!(prefix <> ".crt") == "the data CA"

    for {path, mode} <- [{dir, 0o700}, {prefix <> ".pgpass", 0o600}, {prefix <> ".crt", 0o600}] do
      assert (File.stat!(path).mode &&& 0o777) == mode, path
    end

    {:ok, files} = SessionFiles.write(dir, session())
    assert SessionFiles.remove(files) == :ok
    assert File.ls!(dir) == []
    assert SessionFiles.remove(files) == :ok
  end

  test "refuses a directory others can open", %{tmp_dir: tmp} do
    dir = SessionFiles.dir(tmp)
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o755)

    assert SessionFiles.write(dir, session()) ==
             {:error, :failed,
              "Other people can open #{dir}, so ehosctl does not keep the password of a data " <>
                "session there. Make the directory yours, and readable only by you."}

    assert File.ls!(dir) == []
  end

  test "sweeps the files of a process that no longer runs, or of a session that ended", %{
    tmp_dir: tmp
  } do
    dir = SessionFiles.dir(tmp)
    File.mkdir_p!(dir)
    now = DateTime.to_unix(~U[2026-10-28 12:30:00Z])

    files = %{
      running: "100-#{now + 60}-#{@id}.pgpass",
      dead: "200-#{now + 60}-#{@id}.pgpass",
      expired: "100-#{now - 1}-#{@id}.crt",
      other: "notes.txt"
    }

    for {_kind, name} <- files, do: File.write!(Path.join(dir, name), "x")
    Hammox.stub(Ehosctl.OSMock, :alive?, fn pid -> pid == 100 end)

    assert SessionFiles.sweep(dir, DateTime.from_unix!(now)) == :ok
    assert Enum.sort(File.ls!(dir)) == Enum.sort([files.running, files.other])

    assert SessionFiles.sweep(Path.join(tmp, "none"), DateTime.from_unix!(now)) == :ok
  end

  defp session,
    do: %{
      id: @id,
      expires_at: @ends,
      host: "ehos-ledger-rw.ehos-data.svc",
      port: 5432,
      database: "apps",
      user: "ehos_s_abc",
      password: "the-password",
      data_ca: "the data CA"
    }
end
