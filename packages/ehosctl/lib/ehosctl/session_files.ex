defmodule Ehosctl.SessionFiles do
  @moduledoc """
  The two files a database client reads for a data session: the password file, which holds the
  password `ehosctl` made (`Ehosctl.Scram`), and the data CA, which the client verifies the
  database against (`Ehosctl.DataCa`). `libpq` reads them as `PGPASSFILE` and `PGSSLROOTCERT`.

  They are kept in `data-sessions/` of the state directory (`Ehosctl.TokenStore.dir/1`), which
  only the person can open, each file readable only by them. `ehosctl` removes them when the data
  session's command exits. A command that was killed cannot, so each command first removes the
  files that a command no longer running left, or whose data session has expired: each file's
  name holds the process's id and the data session's end. A password left until then opens
  nothing once its data session has ended, since EHOS removes the session's database role.
  """

  alias Ehosctl.PrivateFile

  defstruct [:passfile, :root_cert]

  @typedoc "Where the password file and the data CA of one data session are."
  @type t :: %__MODULE__{passfile: Path.t(), root_cert: Path.t()}

  @typedoc "What the files hold: where the client connects, as whom, and the data session's end."
  @type session :: %{
          id: String.t(),
          expires_at: DateTime.t(),
          host: String.t(),
          port: pos_integer(),
          database: String.t(),
          user: String.t(),
          password: String.t(),
          data_ca: String.t()
        }

  @name ~r/\A(\d+)-(\d+)-[0-9a-f-]{36}\.(pgpass|crt)\z/

  @doc "The directory of the files, in the state directory `state_dir`."
  @spec dir(Path.t()) :: Path.t()
  def dir(state_dir), do: Path.join(state_dir, "data-sessions")

  @doc """
  Writes the password file and the data CA of `session` in `dir`, for this process. Returns where
  they are, or an error that names `dir`.
  """
  @spec write(Path.t(), session()) :: {:ok, t()} | {:error, :failed, Ehosctl.Failure.message()}
  def write(dir, session) do
    prefix = "#{System.pid()}-#{DateTime.to_unix(session.expires_at)}-#{session.id}"

    files = %__MODULE__{
      passfile: Path.join(dir, prefix <> ".pgpass"),
      root_cert: Path.join(dir, prefix <> ".crt")
    }

    with :ok <- PrivateFile.make_dir(dir, private: true),
         :ok <- PrivateFile.write(files.passfile, passfile_line(session)),
         :ok <- PrivateFile.write(files.root_cert, session.data_ca) do
      {:ok, files}
    else
      {:error, reason} ->
        remove(files)
        {:error, :failed, unwritable(dir, reason)}
    end
  end

  defp unwritable(dir, :shared),
    do:
      "Other people can open #{dir}, so ehosctl does not keep the password of a data session " <>
        "there. Make the directory yours, and readable only by you."

  defp unwritable(dir, reason),
    do:
      "#{dir}: ehosctl cannot write the password of the data session there " <>
        "(#{:file.format_error(reason)})."

  @doc """
  The line of a `libpq` password file for `session`:
  `hostname:port:database:username:password`, with `:` and `\\` escaped.

      iex> Ehosctl.SessionFiles.passfile_line(%{host: "db.svc", port: 5432, database: "apps",
      ...>   user: "ehos_s_a", password: "p:w\\\\d"})
      "db.svc:5432:apps:ehos_s_a:p\\\\:w\\\\\\\\d\\n"
  """
  @spec passfile_line(%{
          host: String.t(),
          port: pos_integer(),
          database: String.t(),
          user: String.t(),
          password: String.t()
        }) :: String.t()
  def passfile_line(session) do
    [
      session.host,
      Integer.to_string(session.port),
      session.database,
      session.user,
      session.password
    ]
    |> Enum.map_join(":", &escape/1)
    |> Kernel.<>("\n")
  end

  defp escape(field), do: String.replace(field, ["\\", ":"], &("\\" <> &1))

  @doc "Removes the files of one data session. A file already gone is not an error."
  @spec remove(t()) :: :ok
  def remove(%__MODULE__{passfile: passfile, root_cert: root_cert}) do
    File.rm(passfile)
    File.rm(root_cert)
    :ok
  end

  @doc """
  Removes from `dir` the files whose process no longer runs (`c:Ehosctl.OS.alive?/1`), or whose
  data session ended before `now`. Files of another name are left as they are.
  """
  @spec sweep(Path.t(), DateTime.t()) :: :ok
  def sweep(dir, now) do
    case File.ls(dir) do
      {:ok, names} -> Enum.each(names, &sweep_one(dir, &1, DateTime.to_unix(now)))
      {:error, _reason} -> :ok
    end
  end

  defp sweep_one(dir, name, now) do
    with [_name, pid, ends, _kind] <- Regex.run(@name, name),
         true <- left?(String.to_integer(pid), String.to_integer(ends), now) do
      File.rm(Path.join(dir, name))
    end

    :ok
  end

  defp left?(pid, ends, now), do: ends < now or not Ehosctl.OS.current().alive?(pid)
end
