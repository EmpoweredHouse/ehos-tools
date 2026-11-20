defmodule Ehosctl.PrivateFileTest do
  use Ehosctl.Case, async: true

  alias Ehosctl.PrivateFile

  @moduletag :tmp_dir

  # ehos-tools#1029: the sign-ins, the configuration and a data session's files are written
  # through `write/2`, and no `server down` reaches their directories.
  test "writes a file only the user reads, and removes what a write killed over an hour before left",
       %{tmp_dir: dir} do
    abandoned = Path.join(dir, ".sign-in.QUJDREVGR0hJ.tmp")
    File.mkdir_p!(abandoned)
    File.write!(Path.join(abandoned, "sign-in"), "an older token")
    File.touch!(abandoned, System.os_time(:second) - 2 * 3600)

    assert PrivateFile.write(Path.join(dir, "sign-in"), "the token") == :ok

    assert File.ls!(dir) == ["sign-in"]
    assert File.read!(Path.join(dir, "sign-in")) == "the token"
    assert Bitwise.band(File.stat!(Path.join(dir, "sign-in")).mode, 0o777) == 0o600
  end
end
