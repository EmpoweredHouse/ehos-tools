defmodule Ehosctl.RunnerTest do
  # Not async: it sets the variables a Burrito release sets in this process's own environment,
  # which every async test would otherwise see. ExUnit runs this module after them, alone.
  use Ehosctl.Case, async: false

  alias Ehosctl.RunnerImpl

  @release %{
    "RELEASE_ROOT" => "/opt/ehosctl/0.0.0",
    "RELEASE_SYS_CONFIG" => "/opt/ehosctl/0.0.0/releases/0.0.0/sys",
    "__BURRITO" => "1",
    "__BURRITO_BIN_PATH" => "/usr/local/bin/ehosctl",
    "_IS_TTY" => "1"
  }

  @print ~s(printf '%s|' "${RELEASE_ROOT-unset}" "${RELEASE_SYS_CONFIG-unset}" "${__BURRITO-unset}" "${__BURRITO_BIN_PATH-unset}" "${_IS_TTY-unset}" "${HOME-unset}")

  setup do
    before = Map.new(Map.keys(@release), &{&1, System.get_env(&1)})
    System.put_env(@release)
    on_exit(fn -> Enum.each(before, &restore/1) end)
  end

  test "a program run does not get the variables ehosctl's release set" do
    assert RunnerImpl.run("/bin/sh", ["-c", @print], []) ==
             {"unset|unset|unset|unset|unset|#{System.get_env("HOME")}|", 0}
  end

  test "a program run keeps a release variable its caller sets, and takes out one it unsets" do
    assert RunnerImpl.run("/bin/sh", ["-c", @print],
             env: [{"RELEASE_ROOT", "/srv/shop"}, {"HOME", nil}]
           ) ==
             {"/srv/shop|unset|unset|unset|unset|unset|", 0}
  end

  test "an interactive program does not get the variables ehosctl's release set" do
    check =
      ~s(test -z "${RELEASE_ROOT+x}${RELEASE_SYS_CONFIG+x}${__BURRITO+x}${__BURRITO_BIN_PATH+x}${_IS_TTY+x}")

    assert RunnerImpl.interactive("/bin/sh", ["-c", check], []) == 0
  end

  test "an interactive program keeps a variable its caller sets, and takes out one it unsets" do
    check = ~s(test "$RELEASE_ROOT" = /srv/shop && test -z "${HOME+x}")

    assert RunnerImpl.interactive("/bin/sh", ["-c", check], [
             {"RELEASE_ROOT", "/srv/shop"},
             {"HOME", nil}
           ]) ==
             0
  end

  defp restore({name, nil}), do: System.delete_env(name)
  defp restore({name, value}), do: System.put_env(name, value)
end
