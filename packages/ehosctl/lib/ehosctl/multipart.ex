defmodule Ehosctl.Multipart do
  @moduledoc """
  A `multipart/form-data` body of JSON parts, in the order given, as EHOS reads a deployment's
  graph documents with its manifest (eh-os#785) and a build's parts (eh-os D-146): each part the
  bytes it is given, unchanged, since EHOS keeps and digests them as they were sent.
  """

  @doc """
  The body `Ehosctl.HTTP.request/5` sends, `{:raw, content_type, bytes}`, of `parts`, each
  `{name, bytes}`. The boundary is random, and drawn again in the unlikely case a part holds it.
  """
  @spec body([{String.t(), binary()}]) :: {:raw, String.t(), binary()}
  def body(parts) do
    boundary = boundary(parts)

    bytes =
      IO.iodata_to_binary([
        for {name, part} <- parts do
          [
            "--",
            boundary,
            "\r\ncontent-disposition: form-data; name=\"",
            name,
            "\"\r\ncontent-type: application/json\r\n\r\n",
            part,
            "\r\n"
          ]
        end,
        "--",
        boundary,
        "--\r\n"
      ])

    {:raw, "multipart/form-data; boundary=" <> boundary, bytes}
  end

  defp boundary(parts) do
    boundary = "ehosctl-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    if Enum.any?(parts, fn {_name, part} -> String.contains?(part, boundary) end),
      do: boundary(parts),
      else: boundary
  end
end
