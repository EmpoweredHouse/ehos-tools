defmodule Ehosctl.TokenStore.SecretService do
  @moduledoc """
  The refresh token in the Secret Service on Linux (GNOME Keyring, KWallet), through
  `secret-tool` (T-08): one item per installation, with the attributes `service` `ehosctl:<url>`
  and `account` the installation's name.

  The secret never reaches a command line. `secret-tool store` reads it from its standard input,
  written by `/bin/sh`'s built-in `printf`, which has it in its environment and unsets it before
  `secret-tool` starts: an Erlang port cannot close a program's standard input and still read its
  exit status. `secret-tool lookup` prints it back to `ehosctl` alone, on its standard output,
  without the error stream, which would otherwise be read as part of the token.

  Each operation is first built as data (`command/3`), so tests read what would run.
  """

  @behaviour Ehosctl.TokenStore

  alias Ehosctl.TokenStore
  alias Ehosctl.TokenStore.Keychain

  @doc """
  The command that puts, gets or deletes the secret of `key`. Only `:put` takes the secret, and
  only in the environment.
  """
  @spec command(:put | :get | :delete, TokenStore.key(), String.t() | nil) :: Keychain.command()
  def command(:put, key, secret) do
    %{
      script:
        ~s[printf '%s' "$EHOSCTL_SECRET" | (unset EHOSCTL_SECRET; ] <>
          ~s[exec secret-tool store --label="$3" service "$1" account "$2") 2>&1],
      args: [service(key), key.name, "ehosctl: #{key.name}"],
      env: [{"EHOSCTL_SECRET", secret}]
    }
  end

  def command(:get, key, nil),
    do: %{
      # The secret on standard output alone, and what secret-tool says on its error stream kept
      # apart: an item that is not there is exit 1 with nothing said, and exit 2 here is exit 1
      # with something said, a D-Bus or keyring failure.
      script:
        ~S|exec 3>&1; err=$(secret-tool lookup service "$1" account "$2" 2>&1 1>&3); s=$?; | <>
          ~S|if [ "$s" = 1 ] && [ -n "$err" ]; then exit 2; fi; exit "$s"|,
      args: [service(key), key.name],
      env: []
    }

  def command(:delete, key, nil),
    do: %{
      script: ~s(secret-tool clear service "$1" account "$2" 2>&1),
      args: [service(key), key.name],
      env: []
    }

  @impl TokenStore
  def put(key, secret) do
    case Keychain.run(command(:put, key, secret)) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, "the Secret Service did not keep it: " <> String.trim(output)}
    end
  end

  # `lookup` exits with 1 and prints nothing when there is no such item. Any other answer, a
  # keyring left locked included, is an error, never a sign-in that is not there: that one is
  # forgotten.
  @impl TokenStore
  def get(key) do
    case Keychain.run(command(:get, key, nil)) do
      {output, 0} when output != "" ->
        {:ok, output}

      {"", 1} ->
        :none

      {_output, status} ->
        {:error, "the Secret Service did not answer (secret-tool exited with #{status})"}
    end
  end

  @impl TokenStore
  def delete(key) do
    case Keychain.run(command(:delete, key, nil)) do
      {_output, 0} ->
        :ok

      {output, _status} ->
        {:error, "the Secret Service did not forget it: " <> String.trim(output)}
    end
  end

  defp service(%{url: url}), do: "ehosctl:" <> url
end
