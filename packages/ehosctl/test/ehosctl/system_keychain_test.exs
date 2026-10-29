defmodule Ehosctl.SystemKeychainTest do
  use Ehosctl.Case, async: true
  use Hammox.Protect, module: Ehosctl.SystemKeychainImpl, behaviour: Ehosctl.SystemKeychain

  alias Ehosctl.TokenStore

  test "is macOS's keychain on macOS" do
    mock_type({:unix, :darwin})
    assert backend() == TokenStore.Keychain
  end

  test "is Linux's Secret Service where secret-tool is installed, and none where it is not" do
    mock_type({:unix, :linux})
    expect(Ehosctl.OSMock, :find_executable, fn "secret-tool" -> "/usr/bin/secret-tool" end)
    assert backend() == TokenStore.SecretService

    expect(Ehosctl.OSMock, :find_executable, fn "secret-tool" -> nil end)
    assert backend() == nil
  end

  test "is none on another system" do
    mock_type({:win32, :nt})
    assert backend() == nil
  end

  defp mock_type(type), do: stub(Ehosctl.OSMock, :type, fn -> type end)
end
