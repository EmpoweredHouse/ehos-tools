defmodule Ehosctl.TokenStore.Keychain do
  @moduledoc """
  The refresh token in macOS's keychain, through `security` (T-08): one generic password per
  installation, its service `ehosctl:<url>` and its account the installation's name.

  The secret never reaches a command line. It is added by an `add-generic-password` line written
  to `security -i` on its standard input, as hexadecimal (`-X`), by `/bin/sh`'s built-in `printf`,
  which has it in its environment and unsets it before `security` starts: an Erlang port cannot
  close a program's standard input and still read its exit status. `find-generic-password -w`
  prints it back to `ehosctl` alone, on its standard output, without the error stream, which
  would otherwise be read as part of the token.

  Each operation is first built as data (`command/3`), so tests read what would run.
  """

  @behaviour Ehosctl.TokenStore

  alias Ehosctl.TokenStore

  @security "/usr/bin/security"
  # `security` exits with errSecItemNotFound's code when there is no such item.
  @not_found 44

  @typedoc "A command for `/bin/sh`: its script, the arguments it reads as `$1`…, and its environment."
  @type command :: %{script: String.t(), args: [String.t()], env: [{String.t(), String.t()}]}

  @doc """
  The command that puts, gets or deletes the secret of `key`. Only `:put` takes the secret, and
  only in the environment.
  """
  @spec command(:put | :get | :delete, TokenStore.key(), String.t() | nil) :: command()
  def command(:put, key, secret) do
    %{
      script:
        ~s(printf 'add-generic-password -U -s %s -a %s -X %s\\n' "$1" "$2" "$EHOSCTL_SECRET" ) <>
          ~s[| (unset EHOSCTL_SECRET; exec #{@security} -i) 2>&1],
      args: [service(key), key.name],
      env: [{"EHOSCTL_SECRET", Base.encode16(secret, case: :lower)}]
    }
  end

  def command(:get, key, nil),
    do: %{
      script: ~s(#{@security} find-generic-password -s "$1" -a "$2" -w 2>/dev/null),
      args: [service(key), key.name],
      env: []
    }

  def command(:delete, key, nil),
    do: %{
      script: ~s(#{@security} delete-generic-password -s "$1" -a "$2" 2>&1),
      args: [service(key), key.name],
      env: []
    }

  @doc "Runs a command built by `command/3`, returning its output and exit status."
  @spec run(command()) :: {String.t(), non_neg_integer()}
  def run(%{script: script, args: args, env: env}),
    do: System.cmd("/bin/sh", ["-c", script, "sh" | args], env: env, stderr_to_stdout: true)

  @impl TokenStore
  def put(key, secret) do
    case run(command(:put, key, secret)) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, "the keychain did not keep it: " <> String.trim(output)}
    end
  end

  @impl TokenStore
  def get(key) do
    case run(command(:get, key, nil)) do
      {output, 0} ->
        {:ok, String.trim_trailing(output, "\n")}

      {_output, @not_found} ->
        :none

      {_output, status} ->
        {:error, "the keychain did not answer (security exited with #{status})"}
    end
  end

  @impl TokenStore
  def delete(key) do
    case run(command(:delete, key, nil)) do
      {_output, status} when status in [0, @not_found] -> :ok
      {output, _status} -> {:error, "the keychain did not forget it: " <> String.trim(output)}
    end
  end

  defp service(%{url: url}), do: "ehosctl:" <> url
end
