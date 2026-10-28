defmodule Ehosctl.ServerRelease do
  @moduledoc """
  The EHOS release whose OpenTofu modules make an installation's server (eh-os D-92, eh-os#415).

  A release is kept beside the installation, in `~/.ehos/<name>/release/`: its `release.json` and
  the modules' archive that `release.json` names, `ehos-modules.tar.gz`, unpacked into
  `release/modules/` once the archive's SHA-256 is the one named (`EhosPlatform.Source.release/1`).
  That checks the archive is the one the release names, not who made the release. Every `server`
  command plans against the kept modules, so `down`, `status` and `tunnel` use what made the
  server with no network and no GitHub token.

  Which release:

    * `up` takes the one `--version` names, else the one kept, else the newest. A release it
      downloads is checked and unpacked in `release.next/`, beside the kept one, and kept only
      once `up` has succeeded (`keep/1`); a refused or failed `up` leaves the kept one
      (`discard/1`).
    * `down`, `status` and `tunnel` take the kept one, and refuse another `--version`: only `up`,
      whose plan shows the change, moves a server to other modules. A kept release whose archive
      is gone is downloaded again, and refused unless it still names the same archive. A server
      made with `mix ehos.server`, which kept none, takes the newest, or the one `--version`
      names, checked and kept at once.
  """

  alias Ehosctl.GitHub
  alias Ehosctl.Refusal
  alias EhosPlatform.Source

  # The modules are a few hundred kilobytes; `EhosPlatform.Source` refuses an archive over 10 MiB.
  @max_archive_bytes 10 * 1024 * 1024
  @max_release_json_bytes 64 * 1024
  @archive "ehos-modules.tar.gz"
  # Written once the archive is unpacked, last: the SHA-256 of the archive `modules/` came from.
  @unpacked "modules.sha256"

  @type error :: {:error, Ehosctl.Output.kind(), String.t()}

  @doc """
  The source of the installation in `dir` (`~/.ehos/<name>`), and its version: the release kept
  there, or the one `version` names, or the newest, as the module's documentation says. `command`
  is `:up` or `:other`. `pending?` is true when `up` downloaded a release it has not kept yet,
  which `keep/1` keeps and `discard/1` drops. `opts` are `Ehosctl.GitHub`'s.
  """
  @spec source(Path.t(), String.t() | nil, :up | :other, keyword()) ::
          {:ok, Source.t(), String.t(), pending? :: boolean()} | error()
  def source(dir, version, command, opts) do
    release_dir = Path.join(dir, "release")
    restore(release_dir)

    with {:ok, kept} <- kept(release_dir, command, version),
         :ok <- may_move(kept, version, command, Path.basename(dir)) do
      wanted = version || (kept && kept["version"])

      cond do
        kept && wanted == kept["version"] && File.regular?(Path.join(release_dir, @archive)) ->
          kept_source(release_dir, kept, wanted)

        command == :up ->
          up_source(release_dir, kept, wanted, opts)

        true ->
          other_source(dir, release_dir, kept, wanted, opts)
      end
    end
  end

  defp kept_source(release_dir, kept, wanted) do
    with {:ok, source} <- unpacked(release_dir, kept), do: {:ok, source, wanted, false}
  end

  defp up_source(release_dir, kept, wanted, opts) do
    # The kept version downloaded again must still name the same archive; only another
    # version, asked by name, may name other modules.
    same = if kept && wanted == kept["version"], do: kept

    with {:ok, source, described} <- fetched(release_dir, wanted, same, opts),
         do: {:ok, source, described["version"], true}
  end

  # `down`, `status` or `tunnel`: kept at once, since no plan will show a change.
  defp other_source(dir, release_dir, kept, wanted, opts) do
    with {:ok, _source, described} <- fetched(release_dir, wanted, kept, opts),
         :ok <- keep(dir),
         {:ok, source} <- unpacked(release_dir, described),
         do: {:ok, source, described["version"], false}
  end

  @doc "Keeps the release `source/4` downloaded for `up`, in place of the one kept before."
  @spec keep(Path.t()) :: :ok | error()
  # sobelow_skip ["Traversal.FileModule"]
  def keep(dir) do
    release_dir = Path.join(dir, "release")
    previous = release_dir <> ".previous"

    with {:ok, _} <- File.rm_rf(previous),
         :ok <- move_aside(release_dir, previous),
         :ok <- File.rename(release_dir <> ".next", release_dir) do
      File.rm_rf(previous)
      :ok
    else
      {:error, reason, _file} -> cannot_keep(release_dir, reason)
      {:error, reason} -> cannot_keep(release_dir, reason)
    end
  end

  @doc "Drops the release `source/4` downloaded for an `up` that did not succeed."
  @spec discard(Path.t()) :: :ok
  def discard(dir) do
    File.rm_rf(Path.join(dir, "release.next"))
    :ok
  end

  @doc "The version of the release kept in `release_dir`, or `nil`."
  @spec kept_version(Path.t()) :: String.t() | nil
  def kept_version(release_dir) do
    case read_release_json(release_dir) do
      {:ok, %{"version" => version}} -> version
      _none -> nil
    end
  end

  # A `keep/1` interrupted between its two renames leaves no `release/`, the old release aside and
  # the new one beside it. Only `keep/1` makes that, and only for a release that made the server
  # or was checked to, so the keep is finished; with no new one, the old one is put back.
  defp restore(release_dir) do
    previous = release_dir <> ".previous"
    next = release_dir <> ".next"

    cond do
      File.exists?(release_dir) or not File.dir?(previous) -> :ok
      File.dir?(next) -> with(:ok <- File.rename(next, release_dir), do: File.rm_rf(previous))
      true -> File.rename(previous, release_dir)
    end
  end

  # No release kept is `nil`. One that cannot be read is refused to any command that would
  # otherwise take another release's modules for the server without being asked; `up` given
  # `--version` takes that one.
  defp kept(release_dir, command, version) do
    case read_release_json(release_dir) do
      {:ok, described} ->
        {:ok, described}

      {:error, _kind, _message} = error ->
        cond do
          not File.exists?(release_dir) -> {:ok, nil}
          command == :up and is_binary(version) -> {:ok, nil}
          true -> error
        end
    end
  end

  defp may_move(%{"version" => kept}, version, :other, name)
       when is_binary(version) and kept != version,
       do:
         {:error, :invalid,
          "this server was made from EHOS #{kept}'s modules; only `ehosctl server up " <>
            "--installation #{name} --version #{Refusal.shown(version)}` moves it to " <>
            "#{Refusal.shown(version)}'s"}

  defp may_move(_kept, _version, _command, _name), do: :ok

  # Downloaded into `release.next/`, and checked and unpacked there before anything is kept. A
  # release downloaded again for one kept must name the same archive.
  defp fetched(release_dir, version, kept, opts) do
    next = release_dir <> ".next"

    with {:ok, release, described} <- Ehosctl.EhosRelease.find(version, opts),
         :ok <- shaped(described, release.tag),
         :ok <- same_archive(described, kept),
         {:ok, archive} <-
           GitHub.asset(release, described["modules"]["asset"], @max_archive_bytes, opts),
         :ok <- present(archive, release.tag, described),
         :ok <- write_next(next, described, archive),
         {:ok, source} <- unpacked(next, described) do
      {:ok, source, described}
    else
      error ->
        File.rm_rf(next)
        error
    end
  end

  # What a release must name for a server to be made from it, each part in the form it takes, so
  # nothing of it reaches the terminal unread: a release from before eh-os D-92 names none.
  defp shaped(nil, tag),
    do: {:error, :failed, "#{tag} has no release.json to make a server from."}

  defp shaped(described, tag) do
    if shaped?(described),
      do: :ok,
      else:
        {:error, :failed,
         "#{tag} names no chart and modules, which a server is made from; take a later " <>
           "release with --version."}
  end

  defp shaped?(%{
         "version" => version,
         "chart" => chart,
         "modules" => %{"asset" => asset, "sha256" => sha256}
       })
       when is_binary(version) and is_binary(chart) and is_binary(asset) and is_binary(sha256) do
    match?({:ok, _}, Version.parse(version)) and Ehosctl.Output.printable?(version) and
      chart =~ ~r/\Aoci:\/\/[a-z0-9.\/_-]+@sha256:[0-9a-f]{64}\z/ and
      asset =~ ~r/\A[A-Za-z0-9._-]+\z/ and sha256 =~ ~r/\A[0-9a-f]{64}\z/
  end

  defp shaped?(_described), do: false

  defp same_archive(_described, nil), do: :ok

  defp same_archive(described, kept) do
    if described["modules"]["sha256"] == kept["modules"]["sha256"] and
         described["chart"] == kept["chart"],
       do: :ok,
       else:
         {:error, :failed,
          "EHOS #{kept["version"]}'s release on GitHub no longer names the modules this server " <>
            "was made from, and their archive is gone from here; nothing was changed"}
  end

  defp present(nil, tag, described),
    do:
      {:error, :failed,
       "#{tag} has no #{described["modules"]["asset"]}, which its release.json names."}

  defp present(_archive, _tag, _described), do: :ok

  # sobelow_skip ["Traversal.FileModule"]
  defp write_next(next, described, archive) do
    with :ok <- File.mkdir_p(Path.dirname(next)),
         :ok <- File.chmod(Path.dirname(next), 0o700),
         {:ok, _} <- File.rm_rf(next),
         :ok <- File.mkdir(next),
         :ok <- File.chmod(next, 0o700),
         :ok <- File.write(Path.join(next, "release.json"), JSON.encode!(described)),
         :ok <- File.write(Path.join(next, @archive), archive) do
      :ok
    else
      {:error, reason, _file} -> cannot_keep(next, reason)
      {:error, reason} -> cannot_keep(next, reason)
    end
  end

  defp move_aside(dir, previous) do
    if File.exists?(dir), do: File.rename(dir, previous), else: :ok
  end

  defp cannot_keep(dir, reason),
    do: {:error, :failed, "cannot keep the release in #{dir}: #{:file.format_error(reason)}"}

  defp read_release_json(release_dir) do
    file = Path.join(release_dir, "release.json")

    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_release_json_bytes <-
           File.stat(file),
         {:ok, bytes} <- File.read(file),
         {:ok, described} <- JSON.decode(bytes),
         true <- shaped?(described) do
      {:ok, described}
    else
      _unread ->
        name = release_dir |> Path.dirname() |> Path.basename()

        {:error, :failed,
         "#{file} is missing or is not a release's; `ehosctl server up --installation #{name} " <>
           "--version <the server's release>` keeps one again"}
    end
  end

  # The modules of `release_dir`'s archive: unpacked again unless `modules/` is already that
  # archive's, as the marker written after the last unpack says.
  defp unpacked(release_dir, described) do
    sha256 = described["modules"]["sha256"]
    modules = Path.join(release_dir, "modules")
    marker = Path.join(release_dir, @unpacked)

    if File.read(marker) == {:ok, sha256} and File.dir?(modules) do
      {:ok, %Source{chart: {:oci, described["chart"]}, modules: modules}}
    else
      File.rm(marker)

      case Source.release(
             chart: described["chart"],
             modules: {Path.join(release_dir, @archive), sha256},
             into: modules
           ) do
        {:ok, source} ->
          File.write(marker, sha256)
          {:ok, source}

        {:error, message} ->
          {:error, :failed, message}
      end
    end
  end
end
