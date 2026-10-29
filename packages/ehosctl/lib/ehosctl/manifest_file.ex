defmodule Ehosctl.ManifestFile do
  @moduledoc """
  An application manifest read from a file, or from stdin as `-`, for the commands that send one
  to EHOS (`ehosctl deploy`, `ehosctl apps register`): its bytes as they are, since EHOS keeps and
  digests a manifest as it was sent, at most 1 MiB, and UTF-8.
  """

  alias Ehosctl.Api
  alias Ehosctl.Refusal

  # EHOS takes a manifest of at most 1 MiB; a larger one is refused before it is read whole.
  @max_bytes 1_048_576

  @doc "The most bytes a manifest, or a graph document, may be."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  The bytes of the manifest in `file`, or on stdin for `-`, or an error of kind `:invalid`. `opts`
  may give `:what`, what the file is said to be when it is refused: `"manifest"` unless it says
  another, such as `"graph document"`, which EHOS takes with a deployment under the same bounds
  (eh-os D-123). `:larger` is the sentence a file past 1 MiB is refused with, followed by where it
  was read from, for a caller that refuses it in the words EHOS would answer.
  """
  @spec read(String.t(), keyword()) :: {:ok, binary()} | {:error, :invalid, String.t()}
  # Both are read as bytes, at most one past the bound, so a device or a pipe that never ends is
  # refused rather than read whole.
  def read("-", opts) do
    case Ehosctl.Terminal.current().read_input(@max_bytes + 1) do
      bytes when is_binary(bytes) -> checked(bytes, "stdin", opts)
      :eof -> {:ok, ""}
      {:error, reason} -> {:error, :invalid, "cannot read stdin: #{inspect(reason)}"}
    end
  end

  def read(file, opts) do
    read =
      File.open(file, [:read, :binary], fn device ->
        case IO.binread(device, @max_bytes + 1) do
          :eof -> ""
          bytes -> bytes
        end
      end)

    case read do
      {:ok, bytes} when is_binary(bytes) ->
        checked(bytes, shown_path(file), opts)

      {:ok, {:error, reason}} ->
        {:error, :invalid, "cannot read #{shown_path(file)}: #{:file.format_error(reason)}"}

      {:error, reason} ->
        {:error, :invalid, "cannot read #{shown_path(file)}: #{:file.format_error(reason)}"}
    end
  end

  defp what(opts), do: Keyword.get(opts, :what, "manifest")

  # A manifest is JSON, so UTF-8; bytes that are not are refused here rather than sent.
  defp checked(bytes, where, opts) do
    cond do
      byte_size(bytes) > @max_bytes ->
        too_large(where, opts)

      not String.valid?(bytes) ->
        {:error, :invalid, "#{where} is not UTF-8, so it is not a #{what(opts)}."}

      true ->
        {:ok, bytes}
    end
  end

  defp too_large(where, opts) do
    case Keyword.fetch(opts, :larger) do
      {:ok, larger} ->
        {:error, :invalid, "#{larger}: #{where}."}

      :error ->
        {:error, :invalid,
         "#{where} is larger than #{@max_bytes} bytes, which is the most a #{what(opts)} may be."}
    end
  end

  defp shown_path(path), do: Refusal.shown(path)

  @doc """
  EHOS's refusal of a manifest it was sent, its sentence with each of its `reasons` under it: the
  sentence says only that it was refused, and each reason names a field.
  """
  @spec refused(Ehosctl.HTTP.answer(), {Ehosctl.Config.name(), Ehosctl.Config.installation()}) ::
          {:error, Ehosctl.Output.kind(), String.t()}
  def refused(%{body: body} = answer, installation) do
    {:error, kind, message} = Api.refusal(answer, installation)

    reasons =
      case body do
        %{"reasons" => reasons} when is_list(reasons) -> reasons
        _other -> []
      end

    lines = for reason <- reasons, is_binary(reason), do: "\n  - " <> Refusal.shown(reason)
    {:error, kind, Enum.join([message | lines])}
  end

  @doc "Where a manifest was read from, as an error names it: `stdin` for `-`."
  @spec where(String.t()) :: String.t()
  def where("-"), do: "stdin"
  def where(file), do: shown_path(file)
end
