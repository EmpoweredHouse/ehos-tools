defmodule EhosRelease.VersionFileTest do
  use ExUnit.Case, async: true

  alias EhosRelease.VersionFile

  test "writes a line holding a backslash as it is, never as a back-reference" do
    assert VersionFile.replace(~s(v = "0.1.0" \\1\n), ~s(v = "{version}" \\1), "0.2.0") ==
             {:ok, ~s(v = "0.2.0" \\1\n)}
  end
end
