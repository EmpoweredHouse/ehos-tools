defmodule Ehosctl.ServerRelease do
  @moduledoc """
  The EHOS release whose OpenTofu modules make an installation's server (eh-os D-92, eh-os#415).

  `ehosctl server up` downloads a release's `release.json` and the modules' archive it names,
  `ehos-modules.tar.gz`, and keeps both beside the installation, in `~/.ehos/<name>/release/`.
  Every `server` command then checks the archive against the SHA-256 that `release.json` names
  and unpacks it into `release/modules/` (`EhosPlatform.Source.release/1`), so `down`, `status` and
  `tunnel` plan against the modules that made the server, with no network and no GitHub token.

  Which release: `--version` on `up`, else the one kept, else the newest. `down`, `status` and
  `tunnel` refuse a `--version` other than the one kept: only `up`, whose plan shows the change,
  moves a server to other modules. A server made with `mix ehos.server`, which kept none, takes
  the newest release's, and keeps it.
  """

  alias EhosPlatform.Source
  alias Ehosctl.GitHub

  # The modules are a few hundred kilobytes; `EhosPlatform.Source` refuses an archive over 10 MiB.
  @max_archive_bytes 10 * 1024 * 1024
  @max_release_json_bytes 64 * 1024

  @type error :: {:error, Ehosctl.Output.kind(), String.t()}

  @doc """
  The source of the installation in `dir` (`~/.ehos/<name>`), and the version it is: the release
  kept there, or the one `version` names, or the newest, downloaded and kept first. `command` is
  `:up`, which may move the server to another release, or another, which may not. `opts` are
  `Ehosctl.GitHub`'s.
  """
  @spec source(Path.t(), String.t() | nil, :up | :other, keyword()) ::
          {:ok, Source.t(), String.t()} | error()
  def source(dir, version, command, opts) do
    release_dir = Path.join(dir, "release")
    kept = kept_version(release_dir)

    with :ok <- may_move(kept, version, command),
         :ok <- fetched(release_dir, kept, version, opts),
         {:ok, described} <- read_release_json(release_dir),
         {:ok, source} <- unpacked(release_dir, described) do
      {:ok, source, described["version"]}
    end
  end

  @doc "The version of the release kept in `dir`'s `release/`, or `nil`."
  @spec kept_version(Path.t()) :: String.t() | nil
  def kept_version(release_dir) do
    case read_release_json(release_dir) do
      {:ok, %{"version" => version}} -> version
      _none -> nil
    end
  end

  defp may_move(kept, version, :other)
       when is_binary(kept) and is_binary(version) and kept != version,
       do:
         {:error, :invalid,
          "this server was made from EHOS #{kept}'s modules; only `ehosctl server up --version " <>
            "#{version}` moves it to #{version}'s"}

  defp may_move(_kept, _version, _command), do: :ok

  defp fetched(release_dir, kept, version, opts) do
    if is_binary(kept) and (is_nil(version) or version == kept) and
         File.regular?(Path.join(release_dir, "ehos-modules.tar.gz")),
       do: :ok,
       else: download(release_dir, version, opts)
  end

  defp download(release_dir, version, opts) do
    with {:ok, releases} <- GitHub.releases("ehos", opts),
         {:ok, release} <- chosen(releases, version),
         {:ok, described} <- GitHub.release_json(release, opts),
         {:ok, modules} <- modules(described, release),
         {:ok, archive} <- GitHub.asset(release, modules["asset"], @max_archive_bytes, opts) do
      if archive,
        do: keep(release_dir, described, archive),
        else:
          {:error, :failed,
           "#{release.tag} has no #{modules["asset"]}, which its release.json names."}
    end
  end

  defp chosen([], _version),
    do: {:error, :failed, "EHOS has no release yet to make a server from."}

  defp chosen([newest | _], nil), do: {:ok, newest}

  defp chosen(releases, version) do
    case Enum.find(releases, &(&1.version == version)) do
      nil -> {:error, :invalid, "EHOS has no release #{Ehosctl.Refusal.shown(version)}."}
      release -> {:ok, release}
    end
  end

  # A release from before eh-os D-92 names no modules, so no server can be made from it.
  defp modules(nil, release),
    do: {:error, :failed, "#{release.tag} has no release.json to make a server from."}

  defp modules(
         %{"chart" => chart, "modules" => %{"asset" => asset, "sha256" => sha} = modules},
         _release
       )
       when is_binary(chart) and is_binary(asset) and is_binary(sha),
       do: {:ok, modules}

  defp modules(_described, release),
    do:
      {:error, :failed,
       "#{release.tag} names no chart and modules, which a server is made from; take a later " <>
         "release with --version."}

  # Written beside the kept files and renamed over them, so the kept release is one or the other.
  # sobelow_skip ["Traversal.FileModule"]
  defp keep(release_dir, described, archive) do
    next = release_dir <> ".next"
    previous = release_dir <> ".previous"

    with :ok <- File.mkdir_p(Path.dirname(release_dir)),
         :ok <- File.chmod(Path.dirname(release_dir), 0o700),
         {:ok, _} <- File.rm_rf(next),
         :ok <- File.mkdir(next),
         :ok <- File.chmod(next, 0o700),
         :ok <- File.write(Path.join(next, "release.json"), JSON.encode!(described)),
         :ok <- File.write(Path.join(next, "ehos-modules.tar.gz"), archive),
         {:ok, _} <- File.rm_rf(previous),
         :ok <- move_aside(release_dir, previous),
         :ok <- File.rename(next, release_dir) do
      File.rm_rf(previous)
      :ok
    else
      {:error, reason, _file} -> cannot_keep(release_dir, reason)
      {:error, reason} -> cannot_keep(release_dir, reason)
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
         {:ok, %{"version" => version} = described} when is_binary(version) <- JSON.decode(bytes) do
      {:ok, described}
    else
      _unread ->
        {:error, :failed, "#{file} is missing or is not a release.json; run `ehosctl server up`"}
    end
  end

  defp unpacked(release_dir, described) do
    case Source.release(
           chart: described["chart"],
           modules:
             {Path.join(release_dir, "ehos-modules.tar.gz"), described["modules"]["sha256"]},
           into: Path.join(release_dir, "modules")
         ) do
      {:ok, source} -> {:ok, source}
      {:error, message} -> {:error, :failed, message}
    end
  end
end
