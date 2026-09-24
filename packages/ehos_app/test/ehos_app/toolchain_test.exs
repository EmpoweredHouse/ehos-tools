defmodule EhosApp.ToolchainTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "names the full Erlang version of the installation", %{tmp_dir: root} do
    major = List.to_string(:erlang.system_info(:otp_release))
    File.mkdir_p!(Path.join([root, "releases", major]))
    File.write!(Path.join([root, "releases", major, "OTP_VERSION"]), "#{major}.1.2\n")

    assert {:ok, [erlang: erlang, elixir: elixir]} = EhosApp.Toolchain.current(root)
    assert erlang == "#{major}.1.2"
    assert elixir == "#{System.version()}-otp-#{major}"
  end

  test "refuses to guess when the full version cannot be read", %{tmp_dir: root} do
    assert EhosApp.Toolchain.current(root) == :error
  end
end
