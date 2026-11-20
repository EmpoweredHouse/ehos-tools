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

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)
end
