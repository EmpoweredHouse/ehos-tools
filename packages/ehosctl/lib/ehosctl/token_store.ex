defmodule Ehosctl.TokenStore do
  @moduledoc """
  Where a sign-in is kept (T-08): its refresh token in the system's keychain, else in a file only
  the user reads, and beside it, in the state directory, the sign-in's file and its lock.

  For an installation named `<name>` (T-07), the state directory holds:

    * `<name>.json`, `0600`: where the refresh token is kept, when it was last renewed, the
      ten-minute credentials, one per audience, until they expire, and the token and revocation
      endpoints `login` read, so a renewal reads neither discovery nor the JWKS again;
    * `<name>.token`, `0600`: the refresh token, when it is kept in a file;
    * `<name>.lock`: present only while a renewal runs (`with_lock/4`).

  Only governed commands reach this module: `Ehosctl.CommandTest` fails on a command of another
  plane that does.

  A backend implements the callbacks below: `Ehosctl.TokenStore.Keychain` (macOS),
  `Ehosctl.TokenStore.SecretService` (Linux) and `Ehosctl.TokenStore.File`. Each takes a `t:key/0`
  and never puts the secret on a command line.
  """

  alias Ehosctl.PrivateFile
  alias Ehosctl.TokenStore

  @version 1

  # How long a command waits for another's renewal, and how often it looks: longer than one
  # renewal can take, three requests of thirty seconds each.
  @lock_timeout_ms 120_000
  @lock_poll_ms 100
  @lock_check_every 10
  # A lock file with no process id in it yet is one being created, unless it is older than this.
  @lock_unwritten_ms 10_000

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
      true -> Path.join([System.user_home!(), ".local", "state", "ehosctl"])
    end
  end

  @doc """
  The backends to keep a new sign-in's refresh token in, in the order to try them, as
  `EHOSCTL_TOKEN_STORE` in `env` asks: `file` for the file alone, `keychain` for the keychain
  alone, and by default the keychain when there is one, then the file.

  `keychain` is the system's backend (`keychain/0`), which tests replace.
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

  @doc """
  The system's keychain, as a backend: macOS's through `security`, Linux's Secret Service through
  `secret-tool` when it is installed, or `nil`.
  """
  @spec keychain() :: module() | nil
  def keychain do
    case :os.type() do
      {:unix, :darwin} -> TokenStore.Keychain
      {:unix, :linux} -> if System.find_executable("secret-tool"), do: TokenStore.SecretService
      _other -> nil
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

  The lock is `<name>.lock`, created exclusively with the process's id and a random tag in it,
  and removed when `fun` returns or raises, but only while it is still this one's. A command that
  finds it waits for up to two minutes (`opts[:timeout]`, in milliseconds), longer than one
  renewal can take.

  A lock whose process no longer runs is broken, one breaker at a time: under `<name>.lock.break`,
  itself created exclusively, the lock is read again and removed only if it is still the dead
  one. Two commands that found it stale cannot both remove it and take it in turn (T-08).
  """
  @spec with_lock(Path.t(), String.t(), (-> result), keyword()) :: result | error()
        when result: term()
  def with_lock(dir, name, fun, opts \\ []) do
    lock = path(dir, name, "lock")
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, @lock_timeout_ms)
    own = "#{System.pid()} #{Base.url_encode64(:crypto.strong_rand_bytes(9))}"

    with :ok <- make_dir(dir),
         :ok <- acquire(lock, own, deadline, 0) do
      try do
        fun.()
      after
        release(lock, own)
      end
    end
  end

  defp release(file, own) do
    if File.read(file) == {:ok, own}, do: File.rm(file)
  end

  defp acquire(lock, own, deadline, polls) do
    case File.open(lock, [:write, :exclusive]) do
      {:ok, device} ->
        # A lock left empty would be taken for one being written, and removed by nobody.
        written =
          with :ok <- :file.write(device, own), do: File.close(device)

        case written do
          :ok ->
            :ok

          {:error, reason} ->
            File.close(device)
            File.rm(lock)
            {:error, :failed, "cannot write #{lock}: #{:file.format_error(reason)}"}
        end

      {:error, :eexist} ->
        # Whether its process runs is asked once a second, not on every poll: it forks `kill`.
        if rem(polls, @lock_check_every) == 0, do: break_if_stale(lock)

        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :failed,
           "another ehosctl is renewing this sign-in; if none is running, remove #{lock} " <>
             "and #{lock}.break"}
        else
          Process.sleep(@lock_poll_ms)
          acquire(lock, own, deadline, polls + 1)
        end

      {:error, reason} ->
        {:error, :failed, "cannot create #{lock}: #{:file.format_error(reason)}"}
    end
  end

  defp break_if_stale(lock) do
    with {:ok, contents} <- File.read(lock),
         true <- stale?(lock, contents) do
      breaker = lock <> ".break"
      own = "#{System.pid()} #{Base.url_encode64(:crypto.strong_rand_bytes(9))}"

      # A breaker is held for a read and a removal. One left by a command that died in between is
      # never broken here, which would let two breakers in: the timeout's message names it.
      case File.open(breaker, [:write, :exclusive]) do
        {:ok, device} ->
          break(device, breaker, own, lock, contents)

        {:error, _another_breaker} ->
          :ok
      end
    end
  end

  defp break(device, breaker, own, lock, contents) do
    written = with :ok <- :file.write(device, own), do: File.close(device)

    try do
      if written == :ok and File.read(lock) == {:ok, contents}, do: File.rm(lock)
    after
      # Removed as its own, or, when it could not be written whole, for nobody else would.
      if written == :ok, do: release(breaker, own), else: File.rm(breaker)
    end
  end

  # A lock is stale when the process that holds it no longer runs. One with no id in it is being
  # created, unless it has been empty for longer than it takes to write one.
  defp stale?(lock, contents) do
    case Integer.parse(contents) do
      # The id alone is what the first version wrote.
      {pid, rest} when rest == "" or binary_part(rest, 0, 1) == " " -> not alive?(pid)
      _unwritten -> older_than?(lock, @lock_unwritten_ms)
    end
  end

  defp alive?(pid) do
    {_output, status} =
      System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)

    status == 0
  end

  defp older_than?(file, ms) do
    case File.stat(file, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> System.os_time(:millisecond) - mtime * 1000 > ms
      {:error, _} -> false
    end
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
