defmodule Ehosctl.Config do
  @moduledoc """
  The installations a person knows, under the names they gave them, and which one is current
  (T-07).

  They are kept in `config.json`, in the first of these that is set:

    1. `$EHOSCTL_CONFIG_DIR`;
    2. `$XDG_CONFIG_HOME/ehosctl`;
    3. `~/.config/ehosctl`, on macOS too, as gh and mise keep theirs.

  The file looks like this, and holds no secret: the sign-in's token is kept apart (T-08).

  ```json
  {
    "version": 1,
    "current": "staging",
    "installations": {
      "local": {"url": "https://ehos.localhost"},
      "staging": {
        "url": "https://ehos.staging.example.com",
        "ca": "-----BEGIN CERTIFICATE-----\nMIIB…\n-----END CERTIFICATE-----\n",
        "sign_in": {
          "subject": "0b9f6c1e-…",
          "email": "grace@example.com",
          "signed_in_at": "2026-10-09T14:02:09Z",
          "expires_at": "2026-10-16T14:02:09Z"
        }
      }
    }
  }
  ```

  `"sign_in"` is who `ehosctl login` signed in, when, and when their seven days end
  (`Ehosctl.Credentials`). `"ca"` is the CA `login` was told to trust through `EHOSCTL_CA_FILE`,
  as PEM, which every later command to that installation trusts besides the system's (T-14).

  A governed command talks to the installation named by `--installation`, else by
  `EHOSCTL_INSTALLATION`, else the current one (`select/3`).

  Every function that touches the disk takes the directory, so tests and callers decide where;
  `dir/1` is where `ehosctl` itself looks. A command that changes the file while another may,
  as two `ehosctl login`s to different installations can, changes it through `update/2`, which
  holds `config.json.lock` beside it (ehos-tools#538).
  """

  alias Ehosctl.FileLock
  alias Ehosctl.PrivateFile

  @version 1

  # A name is typed after `--installation`, so it is kept to what a DNS label allows.
  @name ~r/\A[a-z]([a-z0-9-]{0,61}[a-z0-9])?\z/

  defstruct current: nil, installations: %{}

  @typedoc "An installation's name, as a person types it after `--installation`."
  @type name :: String.t()

  @typedoc """
  What is known of an installation: its `"url"`, and whatever a later version of `ehosctl`
  keeps beside it, which is carried through a rewrite untouched.
  """
  @type installation :: %{required(String.t()) => term()}

  @typedoc "The installations a person knows, and the name of the current one, if any."
  @type t :: %__MODULE__{current: name() | nil, installations: %{name() => installation()}}

  @typedoc "Why the configuration could not be read, written or used, as `Ehosctl.Output` reports it."
  @type error :: {:error, Ehosctl.Output.kind(), String.t()}

  @doc """
  The directory `ehosctl` keeps its configuration in, read from `env` (the process's
  environment by default) and the home directory.

      iex> Ehosctl.Config.dir(%{"EHOSCTL_CONFIG_DIR" => "/tmp/e", "XDG_CONFIG_HOME" => "/x"})
      "/tmp/e"

      iex> Ehosctl.Config.dir(%{"XDG_CONFIG_HOME" => "/x"})
      "/x/ehosctl"

  An empty variable counts as unset, as a shell's `VAR=` means.
  """
  @spec dir(%{String.t() => String.t()}) :: Path.t()
  def dir(env \\ Ehosctl.SystemEnv.current().all()) do
    cond do
      present?(env["EHOSCTL_CONFIG_DIR"]) -> env["EHOSCTL_CONFIG_DIR"]
      present?(env["XDG_CONFIG_HOME"]) -> Path.join(env["XDG_CONFIG_HOME"], "ehosctl")
      true -> Path.join([Ehosctl.OS.current().home(), ".config", "ehosctl"])
    end
  end

  @doc "The configuration file in `dir`."
  @spec path(Path.t()) :: Path.t()
  def path(dir), do: Path.join(dir, "config.json")

  @doc """
  Whether `name` can name an installation: lowercase letters, digits and dashes, starting
  with a letter and ending with a letter or a digit, at most 63 characters, as a DNS label.

      iex> Ehosctl.Config.valid_name?("staging-2")
      true

      iex> Ehosctl.Config.valid_name?("Staging")
      false
  """
  @spec valid_name?(String.t()) :: boolean()
  def valid_name?(name), do: name =~ @name

  @doc """
  Reads the configuration in `dir`. A directory without one holds no installations.

  A file that is not JSON of the shape above (an installation without a `"url"` string, or
  with a control character in it, included), or that a newer `ehosctl` wrote (its
  `"version"` is higher than this one knows), is an error of kind `:failed`: it is never read
  in part, so it is never written back without what this version did not understand.
  """
  @spec read(Path.t()) :: {:ok, t()} | error()
  def read(dir) do
    file = path(dir)

    with {:ok, contents, private?} <- read_file(file),
         {:ok, decoded} <- decode(contents, file) do
      parse(decoded, file, private?)
    end
  end

  @doc """
  Writes `config` to `dir`.

  The file is written whole to a new temporary file beside it, readable only by the user,
  flushed to disk and renamed over the old one, so a command interrupted half way leaves the old
  file rather than half of a new one. It holds no secret, but it says which installations a
  person uses.

  A directory `ehosctl` creates is readable only by the user; one that exists is left as it
  is, since `EHOSCTL_CONFIG_DIR` may name a directory the person uses for more than this. One
  that others can write to is refused: they could put a file or a link where `ehosctl` writes.

  When `config.json` is a symbolic link, as a dotfiles manager makes it, the file it points to
  is rewritten in place, through the link, and the link is kept. That write is not atomic.
  """
  @spec write(t(), Path.t()) :: :ok | error()
  def write(%__MODULE__{} = config, dir) do
    file = path(dir)

    json =
      JSON.encode!(%{
        "version" => @version,
        "current" => config.current,
        "installations" => config.installations
      })

    result =
      with :ok <- PrivateFile.make_dir(dir) do
        case File.read_link(file) do
          # The kernel follows the link as `read/1` did, which a path worked out here would not
          # always do (a `..` after a linked directory).
          {:ok, _target} -> through_link(config, file, json)
          {:error, _} -> PrivateFile.write(file, [json, ?\n])
        end
      end

    case result do
      :ok ->
        :ok

      {:error, :shared_ca} ->
        shared_ca(file)

      {:error, :shared} ->
        shared_dir(dir)

      {:error, reason} ->
        {:error, :failed, "cannot write #{file}: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  Changes the configuration in `dir` by `change`, a function of the one read that returns
  `{:ok, changed}` or an error, holding `config.json.lock` from the read to the write, so a
  change another command makes at the same time is kept rather than written over
  (`Ehosctl.FileLock.with_lock/3`).

  Returns the configuration as it was read and as it was written, or the first error of the read,
  `change` or the write. One `change` left as it was is not written.
  """
  @spec update(Path.t(), (t() -> {:ok, t()} | error())) :: {:ok, t(), t()} | error()
  def update(dir, change) do
    file = path(dir)

    with :ok <- made_dir(dir) do
      FileLock.with_lock(file <> ".lock", "another ehosctl is changing #{file}", fn ->
        changed(dir, change)
      end)
    end
  end

  defp changed(dir, change) do
    with {:ok, read} <- read(dir),
         {:ok, written} <- change.(read),
         :ok <- written(read, written, dir),
         do: {:ok, read, written}
  end

  defp written(same, same, _dir), do: :ok
  defp written(_read, config, dir), do: write(config, dir)

  defp made_dir(dir) do
    case PrivateFile.make_dir(dir) do
      :ok -> :ok
      {:error, :shared} -> shared_dir(dir)
      {:error, reason} -> {:error, :failed, "cannot create #{dir}: #{:file.format_error(reason)}"}
    end
  end

  defp shared_dir(dir),
    do:
      {:error, :failed,
       "#{dir} can be written by others; ehosctl does not keep its configuration there"}

  # A linked file keeps its own mode, so a CA is written through a link only to a file `read/1`
  # will take it back from (T-14), rather than one every later command refuses.
  defp through_link(config, file, json) do
    ca? = Enum.any?(config.installations, fn {_name, value} -> is_map_key(value, "ca") end)

    if ca? and not match?({:ok, _contents, true}, PrivateFile.read(file)),
      do: {:error, :shared_ca},
      else: File.write(file, [json, ?\n])
  end

  defp shared_ca(file) do
    {:error, :failed,
     "#{file} holds a CA ehosctl would trust, and others than you can change it; make it, and " <>
       "the directory it is in, yours and writable by no one else"}
  end

  @doc """
  Makes the installation `name` the current one.
  """
  @spec make_current(t(), name()) :: {:ok, t()} | error()
  def make_current(%__MODULE__{} = config, name) do
    with :ok <- known(config, name), do: {:ok, %{config | current: name}}
  end

  @doc """
  The name of the installation at `url`, if `config` knows one; the first by name if it knows
  several.
  """
  @spec named_at(t(), String.t()) :: name() | nil
  def named_at(%__MODULE__{} = config, url) do
    config.installations
    |> Enum.sort()
    |> Enum.find_value(fn {name, installation} -> if installation["url"] == url, do: name end)
  end

  @doc """
  Puts the installation `name` at `url`, adding it or changing its URL. What else is known of it
  is kept, except its sign-in and its CA when the URL changes, which were another installation's.
  """
  @spec put(t(), name(), String.t()) :: t()
  def put(%__MODULE__{} = config, name, url) do
    installation =
      case config.installations[name] do
        %{"url" => ^url} = installation -> installation
        nil -> %{"url" => url}
        installation -> installation |> Map.drop(["sign_in", "ca"]) |> Map.put("url", url)
      end

    %{config | installations: Map.put(config.installations, name, installation)}
  end

  @doc """
  Keeps `sign_in` beside the installation `name`: who signed in, when, and until when (T-08),
  never a token. `nil` removes it.
  """
  @spec put_sign_in(t(), name(), map() | nil) :: t()
  def put_sign_in(%__MODULE__{} = config, name, sign_in) do
    installation = Map.fetch!(config.installations, name)

    installation =
      if sign_in,
        do: Map.put(installation, "sign_in", sign_in),
        else: Map.delete(installation, "sign_in")

    %{config | installations: Map.put(config.installations, name, installation)}
  end

  @doc """
  Keeps `pem`, the CA certificates `ehosctl login` was told to trust, beside the installation
  `name` (T-14). `nil` removes it.
  """
  @spec put_ca(t(), name(), String.t() | nil) :: t()
  def put_ca(%__MODULE__{} = config, name, pem) do
    installation = Map.fetch!(config.installations, name)

    installation =
      if pem, do: Map.put(installation, "ca", pem), else: Map.delete(installation, "ca")

    %{config | installations: Map.put(config.installations, name, installation)}
  end

  @doc """
  The CA kept for the installation `name`, as `{name, pem}`, for a request's `:ca` option
  (`Ehosctl.TLS.request_opts/3`); `nil` when it has none.
  """
  @spec ca({name(), installation()} | nil) :: {name(), String.t()} | nil
  def ca({name, %{"ca" => pem}}), do: {name, pem}
  def ca(_none), do: nil

  @doc """
  `opts` for a command that talks to `installation`: with its kept CA as `:ca`, trusted by every
  request the command makes for it (T-14), and without one when it has none.

      iex> Ehosctl.Config.trusting([timeout: 1], {"staging", %{"url" => "u", "ca" => "pem"}})
      [ca: {"staging", "pem"}, timeout: 1]

      iex> Ehosctl.Config.trusting([ca: {"other", "pem"}], {"local", %{"url" => "u"}})
      []
  """
  @spec trusting(keyword(), {name(), installation()} | nil) :: keyword()
  def trusting(opts, installation) do
    case ca(installation) do
      nil -> Keyword.delete(opts, :ca)
      ca -> Keyword.put(opts, :ca, ca)
    end
  end

  @doc """
  Forgets the installation `name`. When it was the current one, none is current afterwards:
  `ehosctl` never picks another for the person.
  """
  @spec remove(t(), name()) :: {:ok, t()} | error()
  def remove(%__MODULE__{} = config, name) do
    with :ok <- known(config, name) do
      current = if config.current == name, do: nil, else: config.current
      {:ok, %{config | current: current, installations: Map.delete(config.installations, name)}}
    end
  end

  @doc """
  The installation a governed command talks to: the one `flag` names (`--installation`),
  else the one `env` names (`EHOSCTL_INSTALLATION`), else the address `EHOSCTL_URL` gives, else
  the current one.

  An address from `EHOSCTL_URL` (T-18) is known to no `config.json`: it is returned under the
  name `#{inspect("EHOSCTL_URL")}`, which no kept installation can have, with `"via" =>
  "EHOSCTL_URL"`, and its credentials come from a GitHub Actions job's token
  (`Ehosctl.GitHubActions`), never from a sign-in. It must be `https://host[:port]`.

  With none of them, or a name that is not in `config`, the command cannot talk to any
  installation, which is an error of kind `:not_signed_in`.
  """
  @spec select(t(), name() | nil, %{String.t() => String.t()}) ::
          {:ok, {name(), installation()}} | error()
  def select(%__MODULE__{} = config, flag, env \\ Ehosctl.SystemEnv.current().all()) do
    from_env = if present?(env["EHOSCTL_INSTALLATION"]), do: env["EHOSCTL_INSTALLATION"]

    cond do
      name = flag || from_env -> named(config, name)
      present?(env["EHOSCTL_URL"]) -> from_url(env["EHOSCTL_URL"])
      true -> current(config)
    end
  end

  defp current(%__MODULE__{current: nil}),
    do: {:error, :not_signed_in, "no installation is current; sign in to one first"}

  defp current(config), do: named(config, config.current)

  defp named(config, name) do
    case Map.fetch(config.installations, name) do
      {:ok, installation} -> {:ok, {name, installation}}
      :error -> {:error, :not_signed_in, "no installation is named #{inspect(name)}"}
    end
  end

  @doc """
  The installation's address as `ehosctl` keeps it: an `https` origin, as `ehosctl login` keeps
  it and `EHOSCTL_URL` gives it. A path, a query, a
  fragment or user information is refused, and so is a character a terminal would act on. EHOS
  signs no one in over plain HTTP, so `ehosctl` does not either.

      iex> Ehosctl.Config.origin("https://EHOS.example.com/")
      {:ok, "https://ehos.example.com"}

      iex> {:error, :invalid, _} = Ehosctl.Config.origin("http://localhost:4000")
  """
  @spec origin(String.t()) :: {:ok, String.t()} | {:error, :invalid, String.t()}
  def origin(url) do
    with true <- Ehosctl.Output.printable?(url) and not String.contains?(url, [" ", "\""]),
         {:ok, %URI{scheme: scheme, host: host} = uri} when is_binary(host) and host != "" <-
           URI.new(url),
         true <- scheme in ["https", "http"] and is_nil(uri.userinfo),
         true <- uri.path in [nil, "", "/"] and is_nil(uri.query) and is_nil(uri.fragment) do
      if scheme == "https",
        do:
          {:ok, URI.to_string(%URI{scheme: scheme, host: String.downcase(host), port: uri.port})},
        else: {:error, :invalid, "#{url} is plain HTTP; EHOS signs people in over https only"}
    else
      _ ->
        {:error, :invalid,
         "#{inspect(url)} is not an installation's address, such as https://ehos.example.com"}
    end
  end

  # The same address `ehosctl login` would keep for it (`origin/1`).
  defp from_url(url) do
    case origin(url) do
      {:ok, address} ->
        {:ok, {"EHOSCTL_URL", %{"url" => address, "via" => "EHOSCTL_URL"}}}

      {:error, _kind, message} ->
        {:error, :invalid, "EHOSCTL_URL: " <> message}
    end
  end

  @doc "Whether `installation` is the address `EHOSCTL_URL` gives (T-18), not a kept one."
  @spec from_url?({name(), installation()} | nil) :: boolean()
  # Its name is no kept installation's, so a `config.json` cannot make one of them look like it.
  def from_url?({"EHOSCTL_URL", %{"via" => "EHOSCTL_URL"}}), do: true
  def from_url?(_installation), do: false

  @doc """
  The installation a command that also runs without one talks to, as `select/3` chooses it from
  the configuration in `opts[:config_dir]`, or `nil` when none is named and none is current. One
  named, by `flag` or `EHOSCTL_INSTALLATION` (in the environment, `Ehosctl.SystemEnv`), must be known.
  """
  @spec chosen(name() | nil, keyword()) :: {:ok, {name(), installation()} | nil} | error()
  def chosen(flag, opts) do
    env = Ehosctl.SystemEnv.current().all()
    config_dir = Keyword.get_lazy(opts, :config_dir, fn -> dir(env) end)

    named? =
      flag != nil or present?(env["EHOSCTL_INSTALLATION"]) or present?(env["EHOSCTL_URL"])

    with {:ok, config} <- read(config_dir) do
      case select(config, flag, env) do
        {:ok, installation} -> {:ok, installation}
        {:error, :not_signed_in, _message} when not named? -> {:ok, nil}
        error -> error
      end
    end
  end

  defp known(config, name) do
    if Map.has_key?(config.installations, name),
      do: :ok,
      else: {:error, :invalid, "no installation is named #{inspect(name)}"}
  end

  defp read_file(file) do
    case PrivateFile.read(file) do
      {:ok, contents, private?} -> {:ok, contents, private?}
      {:error, :enoent} -> {:ok, nil, true}
      {:error, reason} -> {:error, :failed, "cannot read #{file}: #{:file.format_error(reason)}"}
    end
  end

  defp decode(nil, _file), do: {:ok, nil}

  defp decode(contents, file) do
    case JSON.decode(contents) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, :failed, "#{file} is not JSON; fix or remove it"}
    end
  end

  defp parse(nil, _file, _private?), do: {:ok, %__MODULE__{}}

  defp parse(%{"version" => version}, file, _private?)
       when is_integer(version) and version > @version do
    {:error, :failed,
     "#{file} was written by a newer ehosctl (version #{version}); upgrade ehosctl to use it"}
  end

  defp parse(%{"version" => @version, "installations" => installations} = decoded, file, private?)
       when is_map(installations) do
    current = decoded["current"]

    cond do
      not (Enum.all?(installations, fn {name, value} -> valid_name?(name) and valid?(value) end) and
               (is_nil(current) or is_map_key(installations, current))) ->
        malformed(file)

      # T-14: a CA kept here is trusted with the person's sign-ins, so no one else may put one in.
      Enum.any?(installations, fn {_name, value} -> is_map_key(value, "ca") end) and
          not private? ->
        shared_ca(file)

      true ->
        {:ok, %__MODULE__{current: current, installations: installations}}
    end
  end

  defp parse(_decoded, file, _private?), do: malformed(file)

  # Every installation has a URL, and the URL is printed to a terminal, so a file with a
  # character in it that a terminal would act on is refused rather than printed. A CA is PEM, no
  # larger than the file `EHOSCTL_CA_FILE` may name.
  defp valid?(%{"url" => url} = installation) when is_binary(url) do
    ca = Map.get(installation, "ca", "")
    Ehosctl.Output.printable?(url) and is_binary(ca) and byte_size(ca) <= 1_048_576
  end

  defp valid?(_installation), do: false

  defp malformed(file),
    do: {:error, :failed, "#{file} is not an ehosctl configuration; fix or remove it"}

  defp present?(value), do: value not in [nil, ""]
end
