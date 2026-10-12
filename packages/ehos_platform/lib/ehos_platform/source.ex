defmodule EhosPlatform.Source do
  @moduledoc """
  Where what is installed comes from: the chart, and the OpenTofu modules that make a server
  (eh-os D-92).

    * `checkout/1` — a checkout of eh-os: `deploy/charts/ehos`, packaged by `helm package` when it
      is installed, and `deploy/tofu`. How eh-os's own tooling and its CI install the code under
      test.
    * `release/1` — what an EHOS release's `release.json` names: the chart by its digest, which
      Helm installs and checks, and the modules' archive, refused unless its SHA-256 is the one
      named, then unpacked.

  The package never guesses a directory: every caller says which source it installs.
  """

  @enforce_keys [:chart, :modules]
  defstruct @enforce_keys

  @typedoc """
  `chart` is `{:directory, path}` or `{:oci, "oci://…@sha256:…"}`; `modules` is a directory that
  holds `deploy/tofu/<provider>`.
  """
  @type t :: %__MODULE__{
          chart: {:directory, Path.t()} | {:oci, String.t()},
          modules: Path.t()
        }

  @chart "deploy/charts/ehos"
  @tofu "deploy/tofu"

  @doc """
  An eh-os checkout at `root`.

      iex> source = EhosPlatform.Source.checkout("/src/eh-os")
      iex> source.chart
      {:directory, "/src/eh-os/deploy/charts/ehos"}
      iex> source.modules
      "/src/eh-os"
  """
  @spec checkout(Path.t()) :: t()
  def checkout(root) do
    root = Path.expand(root)
    %__MODULE__{chart: {:directory, Path.join(root, @chart)}, modules: root}
  end

  @doc """
  What a release names, once its modules' archive is checked and unpacked into `:into`.

  ## Options

    * `:chart` — the chart by digest, `oci://<repository>@sha256:<64 hex>` (required).
    * `:modules` — `{archive, sha256}`: the path of the release's `ehos-modules.tar.gz` and the
      SHA-256 its `release.json` names (required).
    * `:into` — the directory to unpack the modules into; it is emptied first (required).

  Refused, unpacking nothing, when the chart is not named by digest, the archive's SHA-256 differs,
  or the archive holds anything but files and directories under `deploy/tofu/`.
  """
  @spec release(keyword()) :: {:ok, t()} | {:error, String.t()}
  def release(opts) do
    chart = Keyword.fetch!(opts, :chart)
    {archive, sha256} = Keyword.fetch!(opts, :modules)
    into = opts |> Keyword.fetch!(:into) |> Path.expand()

    # Read once: the bytes checked are the bytes unpacked, whatever happens to the file meanwhile.
    with :ok <- by_digest(chart),
         :ok <- safe_target(into, archive),
         {:ok, bytes} <- read(archive),
         :ok <- same_sha256(archive, bytes, sha256),
         :ok <- inside(archive, bytes),
         :ok <- unpack(archive, bytes, into) do
      {:ok, %__MODULE__{chart: {:oci, chart}, modules: into}}
    end
  end

  @doc "The provider's OpenTofu module in this source."
  @spec module(t(), String.t()) :: Path.t()
  def module(%__MODULE__{modules: root}, provider), do: Path.join([root, @tofu, provider])

  defp by_digest(chart) do
    if chart =~ ~r/\Aoci:\/\/[a-z0-9.\/_-]+@sha256:[0-9a-f]{64}\z/,
      do: :ok,
      else:
        {:error, "The chart is named by digest, oci://<repository>@sha256:<64 hex>, not #{chart}"}
  end

  # The modules are a few hundred kilobytes; anything far larger is not a release's archive.
  @max_archive 10 * 1024 * 1024

  # `into` is emptied: never a directory that holds more than the modules.
  defp safe_target(into, archive) do
    refused = ["/", Path.expand("~"), File.cwd!()]
    archive = Path.expand(archive)

    cond do
      into in refused ->
        {:error, "The modules are not unpacked into #{into}, which is emptied first"}

      archive == into or String.starts_with?(archive, into <> "/") ->
        {:error, "The modules are not unpacked into #{into}, which holds the archive"}

      true ->
        :ok
    end
  end

  defp read(archive) do
    case File.stat(archive) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_archive ->
        case File.read(archive) do
          {:ok, bytes} -> {:ok, bytes}
          {:error, reason} -> {:error, "Could not read #{archive}: #{:file.format_error(reason)}"}
        end

      {:ok, %File.Stat{type: :regular, size: size}} ->
        {:error, "#{archive} is #{size} bytes, more than a release's modules ever are"}

      {:ok, _not_a_file} ->
        {:error, "#{archive} is not a file"}

      {:error, reason} ->
        {:error, "Could not read #{archive}: #{:file.format_error(reason)}"}
    end
  end

  defp same_sha256(archive, bytes, expected) do
    actual = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

    if actual == String.downcase(expected),
      do: :ok,
      else:
        {:error,
         "#{archive} has the SHA-256 #{actual}, not #{expected}, which the release names; " <>
           "nothing was unpacked"}
  end

  # Unpacked, the archive writes only files and directories under deploy/tofu/, with no `..` and
  # no link. `git archive` also lists the directories above it, and the commit in a pax global
  # header, which `:erl_tar` lists as an entry of its own.
  defp inside(archive, bytes) do
    case :erl_tar.table({:binary, bytes}, [:compressed, :verbose]) do
      {:ok, entries} ->
        case Enum.reject(entries, &inside?/1) do
          [] ->
            :ok

          outside ->
            {:error,
             "#{archive} holds what is not a file or directory under #{@tofu}/: " <>
               Enum.map_join(outside, ", ", &List.to_string(elem(&1, 0)))}
        end

      {:error, reason} ->
        {:error, "#{archive} is not a .tar.gz: #{inspect(reason)}"}
    end
  end

  defp inside?(entry) do
    name = entry |> elem(0) |> List.to_string()
    type = elem(entry, 1)

    cond do
      name == "pax_global_header" -> type == :unknown
      name in ["deploy", "deploy/tofu"] -> type == :directory
      String.starts_with?(name, @tofu <> "/") -> type in [:regular, :directory] and safe?(name)
      true -> false
    end
  end

  defp safe?(name), do: ".." not in Path.split(name)

  # Unpacked beside `into`, readable by its owner alone and written by nobody else, whatever
  # modes the archive gives (`git archive` gives 0664), then moved over it: a failure leaves the
  # previous modules as they were.
  defp unpack(archive, bytes, into) do
    staging = "#{into}.unpacking-#{System.unique_integer([:positive])}"
    File.mkdir_p!(Path.dirname(into))
    File.mkdir_p!(staging)
    File.chmod!(staging, 0o700)

    case :erl_tar.extract({:binary, bytes}, [:compressed, cwd: String.to_charlist(staging)]) do
      :ok ->
        restrict(staging)
        File.rm_rf!(into)
        File.rename!(staging, into)

      {:error, reason} ->
        File.rm_rf!(staging)
        {:error, "Could not unpack #{archive}: #{inspect(reason)}"}
    end
  end

  defp restrict(dir) do
    for path <- Path.wildcard(Path.join(dir, "**"), match_dot: true) do
      if File.dir?(path), do: File.chmod!(path, 0o700), else: File.chmod!(path, 0o600)
    end

    File.chmod!(dir, 0o700)
  end
end
