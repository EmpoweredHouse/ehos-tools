defmodule Ehosctl.TokenStore.SecretService do
  @moduledoc """
  The refresh token in the Secret Service on Linux (GNOME Keyring, KWallet), through
  `secret-tool` (T-08): one item per installation, with the attributes `service` `ehosctl:<url>`
  and `account` the installation's name.

  The secret never reaches a command line. `secret-tool store` reads it from its standard input,
  written by `/bin/sh`'s built-in `printf`, which has it in its environment: an Erlang port cannot
  close a program's standard input and still read its exit status. `secret-tool lookup` prints it
  back to `ehosctl` alone.

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
        ~s(printf '%s' "$EHOSCTL_SECRET" | secret-tool store --label="$3" service "$1" account "$2" 2>&1),
      args: [service(key), key.name, "ehosctl: #{key.name}"],
      env: [{"EHOSCTL_SECRET", secret}]
    }
  end

  def command(:get, key, nil),
    do: %{
      script: ~s(secret-tool lookup service "$1" account "$2" 2>&1),
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

  # `lookup` exits with 1 and prints nothing when there is no such item, and prints why when the
  # Secret Service cannot be reached.
  @impl TokenStore
  def get(key) do
    case Keychain.run(command(:get, key, nil)) do
      {output, 0} when output != "" -> {:ok, output}
      {"", _status} -> :none
      {output, _status} -> {:error, "the Secret Service did not answer: " <> String.trim(output)}
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
