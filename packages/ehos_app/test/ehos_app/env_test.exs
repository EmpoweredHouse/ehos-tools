defmodule EhosApp.EnvTest do
  use ExUnit.Case, async: true
  use Hammox.Protect, module: EhosApp.EnvImpl, behaviour: EhosApp.Env

  test "reads a variable the process has" do
    assert get("PATH") == System.get_env("PATH")
  end

  test "reads nothing for a variable the process does not have" do
    assert get("EHOS_APP_ENV_TEST_NEVER_SET") == nil
  end
end
