defmodule EhosPlatform.CommandRunnerEnvTest do
  # Not async: it sets the state's passphrase in this process's own environment, which every
  # async test would otherwise see. ExUnit runs this module after them, alone.
  use ExUnit.Case, async: false

  alias EhosPlatform.CommandRunnerImpl, as: Runner

  @passphrase "a passphrase of 16+"
  @print ~s(printf '%s|' "${EHOS_STATE_PASSPHRASE-unset}" "${TF_VAR_state_passphrase-unset}")

  setup do
    before = System.get_env("EHOS_STATE_PASSPHRASE")
    System.put_env("EHOS_STATE_PASSPHRASE", @passphrase)
    on_exit(fn -> restore(before) end)
  end

  test "no program gets the state's passphrase from this process's environment" do
    assert Runner.run("sh", ["-c", @print]) == {"unset|unset|", 0}
    assert Runner.run_in(System.tmp_dir!(), "sh", ["-c", @print]) == {"unset|unset|", 0}
    assert Runner.run_env("sh", ["-c", @print], []) == {"unset|unset|", 0}
    assert Runner.run_bounded("sh", ["-c", @print], 5_000) == {"unset|unset|", 0}
  end

  test "a program run as tofu is, gets the passphrase only as TF_VAR_state_passphrase" do
    env = [{"TF_VAR_state_passphrase", @passphrase}, {"TF_IN_AUTOMATION", "1"}]

    assert Runner.run_env("sh", ["-c", @print], env) == {"unset|#{@passphrase}|", 0}
  end

  test "a program gets the passphrase when its caller sets it" do
    assert Runner.run_env("sh", ["-c", @print], [{"EHOS_STATE_PASSPHRASE", "another one"}]) ==
             {"another one|unset|", 0}
  end

  defp restore(nil), do: System.delete_env("EHOS_STATE_PASSPHRASE")
  defp restore(value), do: System.put_env("EHOS_STATE_PASSPHRASE", value)
end
