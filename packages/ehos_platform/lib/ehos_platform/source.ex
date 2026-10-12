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

    with :ok <- by_digest(chart),
         :ok <- same_sha256(archive, sha256),
         :ok <- inside(archive),
         :ok <- unpack(archive, into) do
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

  defp same_sha256(archive, expected) do
    case File.open(archive, [:read, :binary]) do
      {:ok, file} ->
        actual =
          file
          |> IO.binstream(65_536)
          |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
          |> :crypto.hash_final()
          |> Base.encode16(case: :lower)

        File.close(file)

        if actual == String.downcase(expected),
          do: :ok,
          else:
            {:error,
             "#{archive} has the SHA-256 #{actual}, not #{expected}, which the release names; " <>
               "nothing was unpacked"}

      {:error, reason} ->
        {:error, "Could not read #{archive}: #{:file.format_error(reason)}"}
    end
  end

  # Unpacked, the archive writes only files and directories under deploy/tofu/, with no `..` and
  # no link. `git archive` also lists the directories above it, and the commit in a pax global
  # header, which `:erl_tar` lists as an entry of its own.
  defp inside(archive) do
    case :erl_tar.table(String.to_charlist(archive), [:compressed, :verbose]) do
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

  defp unpack(archive, into) do
    File.rm_rf!(into)
    File.mkdir_p!(into)

    case :erl_tar.extract(String.to_charlist(archive), [
           :compressed,
           cwd: String.to_charlist(into)
         ]) do
      :ok -> :ok
      {:error, reason} -> {:error, "Could not unpack #{archive}: #{inspect(reason)}"}
    end
  end
end
