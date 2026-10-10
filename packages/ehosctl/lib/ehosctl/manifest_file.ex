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

  @doc """
  The bytes of the manifest in `file`, or on stdin for `-`, or an error of kind `:invalid`. `opts`
  may give `:stdin`, what stdin holds, for the tests.
  """
  @spec read(String.t(), keyword()) :: {:ok, binary()} | {:error, :invalid, String.t()}
  # Both are read as bytes, at most one past the bound, so a device or a pipe that never ends is
  # refused rather than read whole. stdin is in unicode mode (`Ehosctl.Application`), which would
  # turn a byte that is not UTF-8 into a character, so it is read in latin1, which hands each byte
  # on as it came, and set back.
  def read("-", opts) do
    read =
      Keyword.get_lazy(opts, :stdin, fn ->
        :io.setopts(:standard_io, encoding: :latin1)

        try do
          IO.binread(:stdio, @max_bytes + 1)
        after
          :io.setopts(:standard_io, encoding: :unicode)
        end
      end)

    case read do
      bytes when is_binary(bytes) -> checked(bytes, "stdin")
      :eof -> {:ok, ""}
      {:error, reason} -> {:error, :invalid, "cannot read stdin: #{inspect(reason)}"}
    end
  end

  def read(file, _opts) do
    read =
      File.open(file, [:read, :binary], fn device ->
        case IO.binread(device, @max_bytes + 1) do
          :eof -> ""
          bytes -> bytes
        end
      end)

    case read do
      {:ok, bytes} when is_binary(bytes) ->
        checked(bytes, shown_path(file))

      {:ok, {:error, reason}} ->
        {:error, :invalid, "cannot read #{shown_path(file)}: #{:file.format_error(reason)}"}

      {:error, reason} ->
        {:error, :invalid, "cannot read #{shown_path(file)}: #{:file.format_error(reason)}"}
    end
  end

  # A manifest is JSON, so UTF-8; bytes that are not are refused here rather than sent.
  defp checked(bytes, where) do
    cond do
      byte_size(bytes) > @max_bytes ->
        too_large(where)

      not String.valid?(bytes) ->
        {:error, :invalid, "#{where} is not UTF-8, so it is not a manifest."}

      true ->
        {:ok, bytes}
    end
  end

  defp too_large(where),
    do:
      {:error, :invalid,
       "#{where} is larger than #{@max_bytes} bytes, which is the most a manifest may be."}

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
