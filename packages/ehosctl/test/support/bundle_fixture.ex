defmodule Ehosctl.BundleFixture do
  @moduledoc """
  A bundle written as `mix eh_os_contract.bundle --output-dir` writes one (eh-os `docs/bundle.md`),
  for the tests of what reads one, and the parts of a multipart body as EHOS reads them.
  """

  @doc """
  Writes `manifest` and `graphs`, each `{name, bytes}` under `graph/`, into `dir`, with the
  `bundle.json` that names them; returns the index's bytes.
  """
  @spec write(String.t(), binary(), [{String.t(), binary()}]) :: binary()
  def write(dir, manifest, graphs) do
    File.mkdir_p!(Path.join(dir, "graph"))
    File.write!(Path.join(dir, "ehos.manifest.json"), manifest)

    for {name, bytes} <- graphs, do: File.write!(Path.join([dir, "graph", name]), bytes)

    index =
      JSON.encode!(%{
        "schema" => "ehos.bundle/v1",
        "manifest" => file("ehos.manifest.json", manifest),
        "graph" => for({name, bytes} <- graphs, do: file("graph/" <> name, bytes))
      })

    File.write!(Path.join(dir, "bundle.json"), index)
    index
  end

  @doc "A file as `bundle.json` names it."
  @spec file(String.t(), binary()) :: map()
  def file(path, bytes),
    do: %{
      "path" => path,
      "bytes" => byte_size(bytes),
      "sha256" => :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    }

  @doc "The parts of a multipart body, by the boundary its content type names, each a name and bytes."
  @spec parts(map()) :: [{String.t(), binary()}]
  def parts(%{content_type: "multipart/form-data; boundary=" <> boundary, body: body}) do
    ["" | rest] = String.split(body, "--" <> boundary)
    {parts, ["--\r\n"]} = Enum.split(rest, -1)

    for "\r\n" <> part <- parts do
      [headers, bytes] = String.split(part, "\r\n\r\n", parts: 2)
      [_, name] = Regex.run(~r/name="([^"]+)"/, headers)
      {name, String.replace_suffix(bytes, "\r\n", "")}
    end
  end
end
