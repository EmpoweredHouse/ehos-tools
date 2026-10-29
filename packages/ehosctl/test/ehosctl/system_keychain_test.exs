defmodule Ehosctl.SystemKeychainTest do
  use Ehosctl.Case, async: true
  use Hammox.Protect, module: Ehosctl.SystemKeychainImpl, behaviour: Ehosctl.SystemKeychain

  alias Ehosctl.TokenStore

  test "is macOS's keychain on macOS, and Linux's Secret Service where secret-tool is installed" do
    case :os.type() do
      {:unix, :darwin} -> assert backend() == TokenStore.Keychain
      {:unix, :linux} -> assert_linux()
    end
  end

  defp assert_linux do
    expect(Ehosctl.OSMock, :find_executable, fn "secret-tool" -> "/usr/bin/secret-tool" end)
    assert backend() == TokenStore.SecretService

    expect(Ehosctl.OSMock, :find_executable, fn "secret-tool" -> nil end)
    assert backend() == nil
  end
end
