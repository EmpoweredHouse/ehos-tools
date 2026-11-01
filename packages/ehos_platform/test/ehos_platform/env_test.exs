defmodule EhosPlatform.EnvTest do
  use ExUnit.Case, async: true
  use Hammox.Protect, module: EhosPlatform.EnvImpl, behaviour: EhosPlatform.Env

  import Hammox, only: [expect: 4, stub: 3, verify_on_exit!: 1]

  alias EhosPlatform.EnvMock

  doctest EhosPlatform.Env

  setup :verify_on_exit!

  test "a variable that is not set reads as nil" do
    assert get("EHOS_PLATFORM_NOT_SET_" <> Integer.to_string(System.unique_integer([:positive]))) ==
             nil
  end

  test "a variable that is set reads as its value" do
    assert get("PATH") == System.get_env("PATH")
  end

  test "the home directory is the system's" do
    assert user_home() == System.user_home!()
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

  describe "home/1" do
    test "is HOME when it is an absolute path of printable characters without .." do
      mock_home("/home/ada/")
      expect(EnvMock, :user_home, 0, fn -> "/home/operator" end)

      assert EhosPlatform.Env.home(env: EnvMock) == "/home/ada"
    end

    test "is the system's when HOME is not set, relative, not printable or climbs" do
      stub(EnvMock, :user_home, fn -> "/home/operator" end)

      for home <- [nil, "", "home/ada", "/home/ada\u200e", "/home/../ada"] do
        mock_home(home)

        assert EhosPlatform.Env.home(env: EnvMock) == "/home/operator"
      end
    end
  end

  describe "expand/2" do
    test "takes ~ and a path from ~/ under the operator's home" do
      mock_home("/home/ada")

      assert EhosPlatform.Env.expand("~", env: EnvMock) == "/home/ada"
      assert EhosPlatform.Env.expand("~/.ehos/../.oci", env: EnvMock) == "/home/ada/.oci"
    end

    test "reads no home for any other path" do
      expect(EnvMock, :get, 0, fn _name -> nil end)
      expect(EnvMock, :user_home, 0, fn -> "/home/operator" end)

      assert EhosPlatform.Env.expand("/srv/ehos/../keys", env: EnvMock) == "/srv/keys"

      assert EhosPlatform.Env.expand("~ada/keys", env: EnvMock) ==
               Path.join(File.cwd!(), "~ada/keys")
    end
  end

  defp mock_home(home), do: stub(EnvMock, :get, fn "HOME" -> home end)
end
