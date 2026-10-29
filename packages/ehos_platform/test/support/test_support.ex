defmodule EhosPlatform.TestSupport do
  # What the tests of `EhosPlatform.Server` and `EhosPlatform.Install` both build: the calls a
  # mock recorded by sending them to the test's process, and the options every `ssh` call is
  # given. Hidden, since the gate builds the docs in `test`, where `test/support` is compiled, and
  # they are the package's, not its tests'.
  @moduledoc false

  @doc """
  Every message this process has received and not read, oldest first, without waiting for more:
  what the mocks recorded, in the order the code ran them.
  """
  @spec drain() :: [term()]
  def drain, do: drain([])

  defp drain(acc) do
    receive do
      message -> drain([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc """
  The options before the host on every `ssh` call to an installation's server: the operator's
  `key` alone, the installation's own `known_hosts` in `dir`, the host key accepted on first
  contact and checked after, and no question asked.
  """
  @spec ssh_options(Path.t(), Path.t()) :: [String.t()]
  def ssh_options(key, dir) do
    [
      "-i",
      key,
      "-o",
      "IdentitiesOnly=yes",
      "-o",
      "UserKnownHostsFile=#{Path.join(dir, "known_hosts")}",
      "-o",
      "StrictHostKeyChecking=accept-new",
      "-o",
      "BatchMode=yes",
      "-o",
      "ConnectTimeout=10",
      "-o",
      "ServerAliveInterval=15",
      "-o",
      "ServerAliveCountMax=4",
      "-o",
      "LogLevel=ERROR",
      "-o",
      "HashKnownHosts=no"
    ]
  end
end
