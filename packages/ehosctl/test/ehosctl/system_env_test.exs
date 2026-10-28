defmodule Ehosctl.SystemEnvTest do
  use Ehosctl.Case, async: true
  use Hammox.Protect, module: Ehosctl.SystemEnvImpl, behaviour: Ehosctl.SystemEnv

  test "reads a variable of this process, and nil for one that is not set" do
    assert get("PATH") == System.get_env("PATH")
    assert get("EHOSCTL_NOT_SET_" <> Integer.to_string(System.unique_integer([:positive]))) == nil
  end

  test "reads every variable of this process" do
    assert all() == System.get_env()
  end
end
