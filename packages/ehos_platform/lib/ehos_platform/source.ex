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

  # `into` is replaced, so it holds nothing but modules: it does not exist yet, or it is a
  # directory whose only entry is `deploy`, what an earlier unpacking left. Anything else, the
  # home directory or `~/.ehos` among them, or a file, is refused; nothing is deleted to find out.
  defp safe_target(into, archive) do
    archive = Path.expand(archive)

    cond do
      archive == into or String.starts_with?(archive, into <> "/") ->
        {:error, "The modules are not unpacked into #{into}, which holds the archive"}

      not File.exists?(into) ->
        :ok

      File.dir?(into) and File.ls!(into) in [[], ["deploy"]] ->
        :ok

      true ->
        {:error,
         "The modules are not unpacked into #{into}, which holds something else; " <>
           "give a directory of their own"}
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

  # Unpacked beside `into`, into a directory made here and nowhere else, readable by its owner
  # alone and written by nobody else whatever modes the archive gives (`git archive` gives 0664),
  # then swapped for it. A failure leaves the previous modules where they were, and no staging.
  defp unpack(archive, bytes, into) do
    suffix = 8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    staging = "#{into}.unpacking-#{suffix}"
    previous = "#{into}.previous-#{suffix}"

    with :ok <- File.mkdir_p(Path.dirname(into)),
         :ok <- File.mkdir(staging),
         :ok <- File.chmod(staging, 0o700),
         :ok <- extract(bytes, staging),
         :ok <- restrict(staging),
         :ok <- swap(staging, into, previous) do
      :ok
    else
      {:error, reason} ->
        File.rm_rf(staging)
        {:error, "Could not unpack #{archive} into #{into}: #{describe(reason)}"}
    end
  end

  defp extract(bytes, staging),
    do: :erl_tar.extract({:binary, bytes}, [:compressed, cwd: String.to_charlist(staging)])

  defp swap(staging, into, previous) do
    if File.exists?(into) do
      with :ok <- File.rename(into, previous) do
        case File.rename(staging, into) do
          :ok ->
            File.rm_rf(previous)
            :ok

          {:error, reason} ->
            File.rename(previous, into)
            {:error, reason}
        end
      end
    else
      File.rename(staging, into)
    end
  end

  # Walked rather than globbed: a path's own `[` or `*` would make a pattern of it.
  defp restrict(dir) do
    with :ok <- File.chmod(dir, 0o700),
         {:ok, names} <- File.ls(dir) do
      Enum.reduce_while(names, :ok, fn name, :ok ->
        path = Path.join(dir, name)

        result =
          case File.lstat(path) do
            {:ok, %File.Stat{type: :directory}} -> restrict(path)
            {:ok, %File.Stat{type: :regular}} -> File.chmod(path, 0o600)
            {:ok, %File.Stat{type: type}} -> {:error, "#{path} is a #{type}"}
            error -> error
          end

        if result == :ok, do: {:cont, :ok}, else: {:halt, result}
      end)
    end
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason) when is_atom(reason), do: :file.format_error(reason) |> to_string()
  defp describe(reason), do: inspect(reason)
end
