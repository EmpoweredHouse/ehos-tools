defmodule EhosPlatform.EnvTest do
  use ExUnit.Case, async: true
  use Hammox.Protect, module: EhosPlatform.EnvImpl, behaviour: EhosPlatform.Env

  test "a variable that is not set reads as nil" do
    assert get("EHOS_PLATFORM_NOT_SET_" <> Integer.to_string(System.unique_integer([:positive]))) ==
             nil
  end

  test "a variable that is set reads as its value" do
    assert get("PATH") == System.get_env("PATH")
  end

  describe "from/1" do
    test "is the module :env names, else this process's" do
      assert EhosPlatform.Env.from(env: EhosPlatform.EnvMock) == EhosPlatform.EnvMock
      assert EhosPlatform.Env.from([]) == EhosPlatform.EnvImpl
      assert EhosPlatform.Env.from(env: nil) == EhosPlatform.EnvImpl
    end

    test "refuses a boolean, which is no module" do
      assert_raise ArgumentError,
                   ":env must name a module that implements EhosPlatform.Env",
                   fn ->
                     EhosPlatform.Env.from(env: true)
                   end
    end

    test "refuses an environment given as a map, and says none of it" do
      error =
        assert_raise ArgumentError, fn ->
          EhosPlatform.Env.from(env: %{"GHCR_TOKEN" => "fixture-token"})
        end

      assert Exception.message(error) ==
               ":env must name a module that implements EhosPlatform.Env"
    end
  end
end
