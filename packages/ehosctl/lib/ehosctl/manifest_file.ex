defmodule Ehosctl.ManifestFile do
  @moduledoc """
  An application manifest read from a file, or from stdin as `-`, for the commands that send one
  to EHOS (`ehosctl deploy`, `ehosctl apps register`): its bytes as they are, since EHOS keeps and
  digests a manifest as it was sent, at most 1 MiB, and UTF-8. `ehosctl apps register` reads a
  utility service's `ehos.yaml` with it too, under that file's own bound.
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
  may give `:what`, what the file is said to be when it is refused: `"application manifest"`
  unless it says another, such as `"graph document"`, which EHOS takes with a deployment under the
  same bounds (eh-os D-123). It may give `:max_bytes`, a smaller bound for a file EHOS reads less
  of, such as an `ehos.yaml`.
  """
  @spec read(String.t(), keyword()) :: {:ok, binary()} | {:error, :invalid, String.t()}
  # Both are read as bytes, at most one past the bound, so a device or a pipe that never ends is
  # refused rather than read whole.
  def read("-", opts) do
    case Ehosctl.Terminal.current().read_input(max(opts) + 1) do
      bytes when is_binary(bytes) ->
        checked(bytes, "stdin", opts)

      :eof ->
        {:ok, ""}

      {:error, reason} ->
        {:error, :invalid, "stdin: ehosctl cannot read it (#{inspect(reason)})."}
    end
  end

  def read(file, opts) do
    read =
      File.open(file, [:read, :binary], fn device ->
        case IO.binread(device, max(opts) + 1) do
          :eof -> ""
          bytes -> bytes
        end
      end)

    case read do
      {:ok, bytes} when is_binary(bytes) ->
        checked(bytes, shown_path(file), opts)

      {:ok, {:error, reason}} ->
        {:error, :invalid,
         "#{shown_path(file)}: ehosctl cannot read it (#{:file.format_error(reason)})."}

      {:error, reason} ->
        {:error, :invalid,
         "#{shown_path(file)}: ehosctl cannot read it (#{:file.format_error(reason)})."}
    end
  end

  defp what(opts), do: Keyword.get(opts, :what, "application manifest")
  defp max(opts), do: Keyword.get(opts, :max_bytes, @max_bytes)

  defp article(<<vowel, _::binary>> = what) when vowel in ~c"aeiou", do: "an " <> what
  defp article(what), do: "a " <> what

  # A manifest is JSON, so UTF-8; bytes that are not are refused here rather than sent.
  defp checked(bytes, where, opts) do
    cond do
      byte_size(bytes) > max(opts) ->
        too_large(where, opts)

      not String.valid?(bytes) ->
        {:error, :invalid, "#{where} is not UTF-8 text, so it is not #{article(what(opts))}."}

      true ->
        {:ok, bytes}
    end
  end

  defp too_large(where, opts) do
    {:error, :invalid,
     "#{where} is larger than #{max(opts)} bytes. #{String.capitalize(article(what(opts)))} " <>
       "can have #{max(opts)} bytes at most."}
  end

  defp shown_path(path), do: Refusal.shown(path)

  @doc """
  EHOS's refusal of a manifest it was sent, its sentence with each of its `reasons` under it: the
  sentence says only that it was refused, and each reason names a field.
  """
  @spec refused(Ehosctl.HTTP.answer(), {Ehosctl.Config.name(), Ehosctl.Config.installation()}) ::
          Refusal.error()
  def refused(%{body: body} = answer, installation) do
    reasons =
      case body do
        %{"reasons" => reasons} when is_list(reasons) -> reasons
        _other -> []
      end

    lines = for reason <- reasons, is_binary(reason), do: "\n  - " <> Refusal.shown(reason)
    answer |> Api.refusal(installation) |> Refusal.added(Enum.join(lines))
  end

  @doc "Where a manifest was read from, as an error names it: `stdin` for `-`."
  @spec where(String.t()) :: String.t()
  def where("-"), do: "stdin"
  def where(file), do: shown_path(file)
end
