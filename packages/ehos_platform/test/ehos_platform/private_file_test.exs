defmodule EhosPlatform.PrivateFileTest do
  use ExUnit.Case, async: true

  alias EhosPlatform.PrivateFile

  @moduletag :tmp_dir

  test "writes a file only its owner reads, and leaves nothing beside it", %{tmp_dir: dir} do
    file = Path.join(dir, "kubeconfig")

    assert PrivateFile.write(file, ["the ", "credential"]) == :ok

    assert File.read!(file) == "the credential"
    assert mode(file) == 0o600
    assert File.ls!(dir) == ["kubeconfig"]
  end

  test "replaces a file others read, so whoever opened it keeps the contents before",
       %{tmp_dir: dir} do
    file = Path.join(dir, "kubeconfig")
    File.write!(file, "before")
    File.chmod!(file, 0o644)
    {:ok, reader} = File.open(file, [:read, :binary])

    assert PrivateFile.write(file, "the credential") == :ok

    assert IO.binread(reader, :eof) == "before"
    assert File.read!(file) == "the credential"
    assert mode(file) == 0o600
  end

  test "replaces a link rather than writing where it leads", %{tmp_dir: dir} do
    elsewhere = Path.join(dir, "elsewhere")
    File.write!(elsewhere, "untouched")
    file = Path.join(dir, "kubeconfig")
    File.ln_s!(elsewhere, file)

    assert PrivateFile.write(file, "the credential") == :ok

    assert File.read!(elsewhere) == "untouched"
    assert File.read!(file) == "the credential"
    assert File.lstat!(file).type == :regular
  end

  test "leaves the file before, and nothing beside it, when it cannot be renamed",
       %{tmp_dir: dir} do
    # A directory with something in it cannot be renamed over.
    file = Path.join(dir, "kubeconfig")
    File.mkdir_p!(Path.join(file, "in it"))

    assert {:error, reason} = PrivateFile.write(file, "the credential")
    assert reason in [:eexist, :eisdir, :enotempty]

    assert File.ls!(dir) == ["kubeconfig"]
    assert File.ls!(file) == ["in it"]
  end

  test "says why when the directory is not there", %{tmp_dir: dir} do
    assert PrivateFile.write(Path.join([dir, "gone", "kubeconfig"]), "x") == {:error, :enoent}
  end

  test "removes what a killed write left, and nothing else", %{tmp_dir: dir} do
    left = Path.join(dir, ".kubeconfig.Zm9vYmFyYmF6.tmp")
    File.mkdir_p!(left)
    File.write!(Path.join(left, "kubeconfig"), "the credential")

    for name <- ~w(kubeconfig .notes.tmp .kubeconfig.short.tmp),
        do: File.write!(Path.join(dir, name), "kept")

    assert PrivateFile.remove_leftovers(dir) == :ok

    assert Enum.sort(File.ls!(dir)) == ~w(.kubeconfig.short.tmp .notes.tmp kubeconfig)
  end

  # ehos-tools#1029: a write killed before its rename left a copy that nothing removed in
  # ehosctl's own directories, which no `server down` reaches.
  test "removes what a write killed over an hour before left, and not one still running",
       %{tmp_dir: dir} do
    abandoned = leftover(dir, ".token.QUJDREVGR0hJ.tmp")
    running = leftover(dir, ".token.TU5PUFFSU1RV.tmp")
    File.touch!(abandoned, System.os_time(:second) - 3601 - 60)

    assert PrivateFile.write(Path.join(dir, "token"), "the token") == :ok

    assert Enum.sort(File.ls!(dir)) == [Path.basename(running), "token"]
  end

  test "removes only what was changed before the time it is given", %{tmp_dir: dir} do
    old = leftover(dir, ".token.QUJDREVGR0hJ.tmp")
    new = leftover(dir, ".token.TU5PUFFSU1RV.tmp")
    File.touch!(old, 1_000)
    File.touch!(new, 3_000)

    assert PrivateFile.remove_leftovers(dir, before: 2_000) == :ok

    assert File.ls!(dir) == [Path.basename(new)]
  end

  test "removes nothing from a directory that is not there", %{tmp_dir: dir} do
    assert PrivateFile.remove_leftovers(Path.join(dir, "gone")) == :ok
  end

  # A directory a write killed before its rename left, with the file it was writing.
  defp leftover(dir, name) do
    path = Path.join(dir, name)
    File.mkdir_p!(path)
    File.write!(Path.join(path, "token"), "a copy")
    path
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)
end
