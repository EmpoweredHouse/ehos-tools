defmodule Ehosctl.Config do
  @moduledoc """
  The installations a person knows, under the names they gave them, and which one is current
  (T-07).

  They are kept in `config.json`, in the first of these that is set:

    1. `$EHOSCTL_CONFIG_DIR`;
    2. `$XDG_CONFIG_HOME/ehosctl`;
    3. `~/.config/ehosctl`, on macOS too, as gh and mise keep theirs.

  The file looks like this, and holds no secret: the sign-in's token is kept apart.

  ```json
  {
    "version": 1,
    "current": "staging",
    "installations": {
      "local": {"url": "http://ehos.localhost"},
      "staging": {"url": "https://ehos.staging.example.com"}
    }
  }
  ```

  A governed command talks to the installation named by `--installation`, else by
  `EHOSCTL_INSTALLATION`, else the current one (`select/3`).

  Every function that touches the disk takes the directory, so tests and callers decide where;
  `dir/1` is where `ehosctl` itself looks.
  """

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
  def dir(env \\ System.get_env()) do
    cond do
      present?(env["EHOSCTL_CONFIG_DIR"]) -> env["EHOSCTL_CONFIG_DIR"]
      present?(env["XDG_CONFIG_HOME"]) -> Path.join(env["XDG_CONFIG_HOME"], "ehosctl")
      true -> Path.join([System.user_home!(), ".config", "ehosctl"])
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

    with {:ok, contents} <- read_file(file),
         {:ok, decoded} <- decode(contents, file) do
      parse(decoded, file)
    end
  end

  @doc """
  Writes `config` to `dir`.

  The file is written whole to a new temporary file beside it, readable only by the user, and
  renamed over the old one, so a command interrupted half way leaves the old file rather than
  half of a new one. It holds no secret, but it says which installations a person uses.

  A directory `ehosctl` creates is readable only by the user; one that exists is left as it is,
  since `EHOSCTL_CONFIG_DIR` may name a directory the person uses for more than this. When
  `config.json` is a symbolic link, as a dotfiles manager makes it, the file it points to is
  rewritten and the link is kept.
  """
  @spec write(t(), Path.t()) :: :ok | error()
  def write(%__MODULE__{} = config, dir) do
    file = resolve(path(dir))

    # Random rather than `System.unique_integer/1`, which repeats from one run to the next, and
    # opened `:exclusive`, so a file or a link someone else put at that path is never written
    # through.
    temporary =
      Path.join(
        Path.dirname(file),
        ".config.json.#{Base.url_encode64(:crypto.strong_rand_bytes(9))}.tmp"
      )

    json =
      JSON.encode!(%{
        "version" => @version,
        "current" => config.current,
        "installations" => config.installations
      })

    with :ok <- make_dir(dir),
         :ok <- write_new(temporary, [json, ?\n]),
         :ok <- File.rename(temporary, file) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, :failed, "cannot write #{file}: #{:file.format_error(reason)}"}
    end
  end

  defp make_dir(dir) do
    if File.dir?(dir) do
      :ok
    else
      with :ok <- File.mkdir_p(dir), do: File.chmod(dir, 0o700)
    end
  end

  defp write_new(file, contents) do
    with {:ok, device} <- File.open(file, [:write, :exclusive, :binary]) do
      try do
        with :ok <- File.chmod(file, 0o600), do: IO.binwrite(device, contents)
      after
        File.close(device)
      end
    end
  end

  # Follows symbolic links to the file they end at, as many as the kernel would (40 on Linux).
  defp resolve(file, hops \\ 40)
  defp resolve(file, 0), do: file

  defp resolve(file, hops) do
    case File.read_link(file) do
      {:ok, target} -> resolve(Path.expand(target, Path.dirname(file)), hops - 1)
      {:error, _} -> file
    end
  end

  @doc """
  Makes the installation `name` the current one.
  """
  @spec make_current(t(), name()) :: {:ok, t()} | error()
  def make_current(%__MODULE__{} = config, name) do
    with :ok <- known(config, name), do: {:ok, %{config | current: name}}
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
  else the one `env` names (`EHOSCTL_INSTALLATION`), else the current one.

  With none of them, or a name that is not in `config`, the command cannot talk to any
  installation, which is an error of kind `:not_signed_in`.
  """
  @spec select(t(), name() | nil, %{String.t() => String.t()}) ::
          {:ok, {name(), installation()}} | error()
  def select(%__MODULE__{} = config, flag, env \\ System.get_env()) do
    from_env = if present?(env["EHOSCTL_INSTALLATION"]), do: env["EHOSCTL_INSTALLATION"]

    case flag || from_env || config.current do
      nil ->
        {:error, :not_signed_in, "no installation is current; sign in to one first"}

      name ->
        case Map.fetch(config.installations, name) do
          {:ok, installation} -> {:ok, {name, installation}}
          :error -> {:error, :not_signed_in, "no installation is named #{inspect(name)}"}
        end
    end
  end

  defp known(config, name) do
    if Map.has_key?(config.installations, name),
      do: :ok,
      else: {:error, :invalid, "no installation is named #{inspect(name)}"}
  end

  defp read_file(file) do
    case File.read(file) do
      {:ok, contents} -> {:ok, contents}
      {:error, :enoent} -> {:ok, nil}
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

  defp parse(nil, _file), do: {:ok, %__MODULE__{}}

  defp parse(%{"version" => version}, file) when is_integer(version) and version > @version do
    {:error, :failed,
     "#{file} was written by a newer ehosctl (version #{version}); upgrade ehosctl to use it"}
  end

  defp parse(%{"version" => @version, "installations" => installations} = decoded, file)
       when is_map(installations) do
    current = decoded["current"]

    if Enum.all?(installations, fn {name, value} -> valid_name?(name) and valid?(value) end) and
         (is_nil(current) or is_map_key(installations, current)) do
      {:ok, %__MODULE__{current: current, installations: installations}}
    else
      malformed(file)
    end
  end

  defp parse(_decoded, file), do: malformed(file)

  # Every installation has a URL, and the URL is printed to a terminal: a control character in
  # it, written by hand or by a server, could move the cursor, rewrite a line or set the
  # clipboard, so a file with one is refused rather than printed.
  defp valid?(%{"url" => url}) when is_binary(url),
    do: String.printable?(url) and not String.match?(url, ~r/[[:cntrl:]]/u)

  defp valid?(_installation), do: false

  defp malformed(file),
    do: {:error, :failed, "#{file} is not an ehosctl configuration; fix or remove it"}

  defp present?(value), do: value not in [nil, ""]
end
