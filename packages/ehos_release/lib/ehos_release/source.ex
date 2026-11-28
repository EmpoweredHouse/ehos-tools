defmodule EhosRelease.Source do
  @moduledoc """
  A caller's files, read either from its checkout as it stands or as one of its commits has them,
  so that the pins a pull request moves are read against its base without a second checkout.
  """

  @enforce_keys [:dir]
  defstruct [:dir, rev: nil, git: EhosRelease.GitImpl]

  @typedoc "The checkout in `dir`, as it stands when `rev` is nil, or at the commit `rev`."
  @type t :: %__MODULE__{dir: Path.t(), rev: String.t() | nil, git: module()}

  @doc "The checkout in `dir` as it stands."
  @spec checkout(Path.t()) :: t()
  def checkout(dir), do: %__MODULE__{dir: dir}

  @doc "The checkout in `dir` at the commit `rev`, read through `git`."
  @spec at(Path.t(), String.t(), module()) :: t()
  def at(dir, rev, git \\ EhosRelease.GitImpl), do: %__MODULE__{dir: dir, rev: rev, git: git}

  # The largest file read: a caller's mix.lock, workflow or fragment is a few kilobytes, and a
  # larger one is not parsed.
  @max_bytes 1_048_576

  @doc "The file at `path`, or `:missing`. A file larger than 1 MiB is refused unread."
  @spec read(t(), String.t()) :: {:ok, binary()} | :missing | {:error, String.t()}
  def read(%__MODULE__{rev: nil, dir: dir}, path) do
    file = Path.join(dir, path)

    case File.stat(file) do
      {:ok, %File.Stat{size: size}} when size > @max_bytes -> too_large(path)
      {:ok, _stat} -> read_file(file, path)
      {:error, :enoent} -> :missing
      {:error, reason} -> {:error, "#{path} could not be read: #{:file.format_error(reason)}"}
    end
  end

  def read(%__MODULE__{} = source, path) do
    case source.git.show(source.dir, source.rev, path) do
      {:ok, contents} when byte_size(contents) > @max_bytes -> too_large(path)
      other -> other
    end
  end

  defp read_file(file, path) do
    case File.read(file) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, "#{path} could not be read: #{:file.format_error(reason)}"}
    end
  end

  defp too_large(path), do: {:error, "#{path} is larger than 1 MiB, so it is not read"}

  @doc "The files in the directory `path`, not below it, whose name ends in one of `extensions`."
  @spec list(t(), String.t(), [String.t()]) :: {:ok, [String.t()]} | {:error, String.t()}
  def list(%__MODULE__{rev: nil, dir: dir}, path, extensions) do
    case File.ls(Path.join(dir, path)) do
      {:ok, names} -> {:ok, names |> Enum.map(&Path.join(path, &1)) |> only(path, extensions)}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, "#{path} could not be listed: #{:file.format_error(reason)}"}
    end
  end

  def list(%__MODULE__{} = source, path, extensions) do
    with {:ok, files} <- source.git.files(source.dir, source.rev, path) do
      {:ok, only(files, path, extensions)}
    end
  end

  defp only(files, dir, extensions) do
    files
    |> Enum.filter(&(Path.dirname(&1) == dir and Path.extname(&1) in extensions))
    |> Enum.sort()
  end
end
