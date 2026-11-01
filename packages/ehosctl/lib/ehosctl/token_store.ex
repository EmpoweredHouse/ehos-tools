defmodule Ehosctl.TokenStore do
  @moduledoc """
  Where a sign-in is kept (T-08): its refresh token in the system's keychain, else in a file only
  the user reads, and beside it, in the state directory, the sign-in's file and its lock.

  For an installation named `<name>` (T-07), the state directory holds:

    * `<name>.json`, `0600`: where the refresh token is kept, when it was last renewed, the
      ten-minute credentials, one per audience, until they expire, and the token and revocation
      endpoints `login` read, so a renewal reads neither discovery nor the JWKS again;
    * `<name>.token`, `0600`: the refresh token, when it is kept in a file;
    * `<name>.lock`: present only while a renewal runs (`with_lock/3`).

  Only governed commands reach this module: `Ehosctl.CommandTest` fails on a command of another
  plane that does.

  A backend implements the callbacks below: `Ehosctl.TokenStore.Keychain` (macOS),
  `Ehosctl.TokenStore.SecretService` (Linux) and `Ehosctl.TokenStore.File`. Each takes a `t:key/0`
  and never puts the secret on a command line.
  """

  alias Ehosctl.FileLock
  alias Ehosctl.PrivateFile
  alias Ehosctl.TokenStore

  @version 1

  @typedoc "What names one sign-in's refresh token: the state directory, the installation's name and its URL."
  @type key :: %{dir: Path.t(), name: String.t(), url: String.t()}

  @typedoc "Where a refresh token is kept, as `<name>.json` says."
  @type kind :: :keychain | :file

  @typedoc """
  A sign-in, as `<name>.json` keeps it: the installation's URL, where its refresh token is, when it
  was last renewed, the cached credentials by the `resource` they were renewed for, each with its
  expiry, and the endpoints a renewal and a revocation are posted to, or `nil` when the sign-in
  has none, which the next renewal reads from discovery and keeps.
  """
  @type session :: %{
          required(:url) => String.t(),
          required(:store) => kind(),
          required(:renewed_at) => DateTime.t(),
          required(:credentials) => %{
            String.t() => %{token: String.t(), expires_at: DateTime.t()}
          },
          optional(:endpoints) => %{String.t() => String.t() | nil} | nil
        }

  @typedoc "Why the store could not be read or written, as `Ehosctl.Output` reports it."
  @type error :: {:error, Ehosctl.Output.kind(), String.t()}

  @doc "Keeps `secret` under `key`, replacing what was there."
  @callback put(key(), secret :: String.t()) :: :ok | {:error, String.t()}

  @doc "The secret kept under `key`, or `:none`."
  @callback get(key()) :: {:ok, String.t()} | :none | {:error, String.t()}

  @doc "Forgets the secret under `key`; one that is not there is already forgotten."
  @callback delete(key()) :: :ok | {:error, String.t()}

  @doc """
  The state directory, read from `env` (the process's environment by default) and the home
  directory: `$EHOSCTL_STATE_DIR`, else `$XDG_STATE_HOME/ehosctl`, else `~/.local/state/ehosctl`,
  on macOS too.

      iex> Ehosctl.TokenStore.dir(%{"EHOSCTL_STATE_DIR" => "/tmp/s", "XDG_STATE_HOME" => "/x"})
      "/tmp/s"

      iex> Ehosctl.TokenStore.dir(%{"XDG_STATE_HOME" => "/x"})
      "/x/ehosctl"
  """
  @spec dir(%{String.t() => String.t()}) :: Path.t()
  def dir(env \\ Ehosctl.SystemEnv.current().all()) do
    cond do
      present?(env["EHOSCTL_STATE_DIR"]) -> env["EHOSCTL_STATE_DIR"]
      present?(env["XDG_STATE_HOME"]) -> Path.join(env["XDG_STATE_HOME"], "ehosctl")
      true -> Path.join([Ehosctl.OS.current().home(), ".local", "state", "ehosctl"])
    end
  end

  @doc """
  The backends to keep a new sign-in's refresh token in, in the order to try them, as
  `EHOSCTL_TOKEN_STORE` in `env` asks: `file` for the file alone, `keychain` for the keychain
  alone, and by default the keychain when there is one, then the file.

  `keychain` is the system's backend (`Ehosctl.SystemKeychain`), `nil` for none.
  """
  @spec choose(%{String.t() => String.t()}, module() | nil) ::
          {:ok, [{kind(), module()}]} | error()
  def choose(env, keychain) do
    case {env["EHOSCTL_TOKEN_STORE"], keychain} do
      {"file", _keychain} ->
        {:ok, [file: TokenStore.File]}

      {"keychain", nil} ->
        {:error, :failed,
         "EHOSCTL_TOKEN_STORE is keychain, and this system has none ehosctl can use"}

      {"keychain", keychain} ->
        {:ok, [keychain: keychain]}

      {empty, nil} when empty in [nil, ""] ->
        {:ok, [file: TokenStore.File]}

      {empty, keychain} when empty in [nil, ""] ->
        {:ok, [keychain: keychain, file: TokenStore.File]}

      {other, _keychain} ->
        {:error, :invalid, "EHOSCTL_TOKEN_STORE is #{inspect(other)}; it is keychain or file"}
    end
  end

  @doc "The backend that keeps a sign-in's refresh token, from the kind `<name>.json` names."
  @spec backend(kind(), module() | nil) :: {:ok, module()} | error()
  def backend(:file, _keychain), do: {:ok, TokenStore.File}
  def backend(:keychain, keychain) when keychain != nil, do: {:ok, keychain}

  def backend(:keychain, nil),
    do: {:error, :failed, "this sign-in is kept in a keychain this system no longer has"}

  @doc "The file `<name>.<extension>` in the state directory `dir`."
  @spec path(Path.t(), String.t(), String.t()) :: Path.t()
  def path(dir, name, extension), do: Path.join(dir, "#{name}.#{extension}")

  @doc """
  Reads the sign-in to the installation `name` from `dir`, or `:none` when there is none.

  A file that is not a sign-in this version wrote is an error of kind `:failed`, as
  `Ehosctl.Config.read/1` treats its own.
  """
  @spec read(Path.t(), String.t()) :: {:ok, session()} | :none | error()
  def read(dir, name) do
    file = path(dir, name, "json")

    case File.read(file) do
      {:ok, contents} ->
        with {:ok, decoded} <- JSON.decode(contents),
             {:ok, session} <- parse(decoded) do
          {:ok, session}
        else
          _ -> {:error, :failed, "#{file} is not an ehosctl sign-in; run `ehosctl logout`"}
        end

      {:error, :enoent} ->
        :none

      {:error, reason} ->
        {:error, :failed, "cannot read #{file}: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  Writes the sign-in to the installation `name` to `dir`, whole (`Ehosctl.PrivateFile`). `dir`
  must be the user's alone (`Ehosctl.PrivateFile.make_dir/2`).
  """
  @spec write(Path.t(), String.t(), session()) :: :ok | error()
  def write(dir, name, session) do
    json =
      JSON.encode!(%{
        "version" => @version,
        "url" => session.url,
        "store" => Atom.to_string(session.store),
        "renewed_at" => DateTime.to_iso8601(session.renewed_at),
        "credentials" =>
          Map.new(session.credentials, fn {resource, credential} ->
            {resource,
             %{
               "token" => credential.token,
               "expires_at" => DateTime.to_iso8601(credential.expires_at)
             }}
          end),
        "endpoints" => session[:endpoints]
      })

    with :ok <- make_dir(dir) do
      file = path(dir, name, "json")

      case PrivateFile.write(file, [json, ?\n]) do
        :ok ->
          :ok

        {:error, reason} ->
          {:error, :failed, "cannot write #{file}: #{:file.format_error(reason)}"}
      end
    end
  end

  @doc """
  Forgets the sign-in to the installation `name` in `dir`: its refresh token, wherever `session`
  says it is kept, and its file. What is not there is already forgotten.
  """
  @spec forget(Path.t(), String.t(), session(), module() | nil) :: :ok | error()
  def forget(dir, name, session, keychain) do
    key = %{dir: dir, name: name, url: session.url}

    with {:ok, backend} <- backend(session.store, keychain),
         :ok <- deleted(backend.delete(key)) do
      case File.rm(path(dir, name, "json")) do
        result when result in [:ok, {:error, :enoent}] ->
          :ok

        {:error, reason} ->
          {:error, :failed, "cannot remove a sign-in: #{:file.format_error(reason)}"}
      end
    end
  end

  defp deleted(:ok), do: :ok
  defp deleted({:error, message}), do: {:error, :failed, message}

  @doc """
  Runs `fun` holding the lock on the sign-in to the installation `name` in `dir`, and returns
  what it returns.

  The lock is `<name>.lock`, held as `Ehosctl.FileLock.with_lock/3` holds one (T-08): a command
  that finds it waits for up to two minutes, longer than one renewal can take, and one whose
  process no longer runs is broken.
  """
  @spec with_lock(Path.t(), String.t(), (-> result)) :: result | error() when result: term()
  def with_lock(dir, name, fun) do
    lock = path(dir, name, "lock")

    with :ok <- make_dir(dir),
         do: FileLock.with_lock(lock, "another ehosctl is renewing this sign-in", fun)
  end

  defp make_dir(dir) do
    case PrivateFile.make_dir(dir, private: true) do
      :ok ->
        :ok

      {:error, :shared} ->
        {:error, :failed,
         "#{dir} is not yours alone; ehosctl keeps sign-ins only in a directory that is " <>
           "yours and that nobody else can read (chmod 700 #{dir})"}

      {:error, reason} ->
        {:error, :failed, "cannot create #{dir}: #{:file.format_error(reason)}"}
    end
  end

  defp parse(
         %{
           "version" => @version,
           "url" => url,
           "store" => store,
           "renewed_at" => renewed_at,
           "credentials" => credentials
         } = decoded
       )
       when is_binary(url) and store in ["keychain", "file"] and is_map(credentials) do
    with {:ok, renewed_at, _offset} <- DateTime.from_iso8601(renewed_at),
         {:ok, credentials} <- credentials(credentials) do
      {:ok,
       %{
         url: url,
         store: String.to_existing_atom(store),
         renewed_at: renewed_at,
         credentials: credentials,
         endpoints: endpoints(decoded["endpoints"])
       }}
    end
  end

  defp parse(_decoded), do: :error

  # Endpoints a sign-in kept, as strings; anything else is none, which discovery replaces.
  defp endpoints(%{"token" => token} = endpoints) when is_binary(token) do
    case endpoints["revocation"] do
      revocation when is_binary(revocation) or is_nil(revocation) ->
        %{"token" => token, "revocation" => revocation}

      _other ->
        nil
    end
  end

  defp endpoints(_none), do: nil

  defp credentials(credentials) do
    Enum.reduce_while(credentials, {:ok, %{}}, fn
      {resource, %{"token" => token, "expires_at" => expires_at}}, {:ok, acc}
      when is_binary(token) and is_binary(expires_at) ->
        case DateTime.from_iso8601(expires_at) do
          {:ok, expires_at, _offset} ->
            {:cont, {:ok, Map.put(acc, resource, %{token: token, expires_at: expires_at})}}

          _ ->
            {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
  end

  defp present?(value), do: value not in [nil, ""]
end
