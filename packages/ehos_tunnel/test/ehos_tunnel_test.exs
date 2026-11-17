defmodule EhosTunnelTest do
  use ExUnit.Case, async: true

  doctest EhosTunnel.Key
  doctest EhosTunnel.Certificate
  doctest EhosTunnel.Protocol

  test "the release file names the package, its version and the commit, and no interface" do
    commit = String.duplicate("a", 40)

    assert EhosTunnel.release(commit) == %{
             "schema" => "ehos.release/v1",
             "component" => "ehos_tunnel",
             "version" => to_string(Application.spec(:ehos_tunnel, :vsn)),
             "commit" => commit,
             "produces" => [],
             "accepts" => [],
             "requires" => %{}
           }
  end
end
