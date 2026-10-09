defmodule Ehosctl.TokenStore.File do
  @moduledoc """
  The refresh token in `<name>.token` in the state directory, `0600` in a `0700` directory
  (T-08): where there is no keychain, or where `EHOSCTL_TOKEN_STORE=file` asks for it.
  """

  @behaviour Ehosctl.TokenStore

  alias Ehosctl.PrivateFile
  alias Ehosctl.TokenStore

  @doc "The file the refresh token of `key` is kept in."
  @spec path(TokenStore.key()) :: Path.t()
  def path(%{dir: dir, name: name}), do: TokenStore.path(dir, name, "token")

  @impl TokenStore
  def put(key, secret) do
    file = path(key)

    with {:dir, :ok} <- {:dir, PrivateFile.make_dir(key.dir)},
         :ok <- PrivateFile.write(file, secret) do
      :ok
    else
      {:dir, {:error, :shared}} ->
        {:error, "#{key.dir} can be written by others"}

      {:dir, {:error, reason}} ->
        {:error, "cannot create #{key.dir}: #{:file.format_error(reason)}"}

      {:error, reason} ->
        {:error, "cannot write #{file}: #{:file.format_error(reason)}"}
    end
  end

  @impl TokenStore
  def get(key) do
    case File.read(path(key)) do
      {:ok, secret} -> {:ok, secret}
      {:error, :enoent} -> :none
      {:error, reason} -> {:error, "cannot read #{path(key)}: #{:file.format_error(reason)}"}
    end
  end

  @impl TokenStore
  def delete(key) do
    case File.rm(path(key)) do
      result when result in [:ok, {:error, :enoent}] -> :ok
      {:error, reason} -> {:error, "cannot remove #{path(key)}: #{:file.format_error(reason)}"}
    end
  end
end
