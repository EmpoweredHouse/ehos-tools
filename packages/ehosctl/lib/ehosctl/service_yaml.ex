defmodule Ehosctl.ServiceYaml do
  @moduledoc """
  A utility service's `ehos.yaml`, read and checked as EHOS reads it, and the application manifest
  written from it (eh-os
  [D-175](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0175-a-utility-service-is-an-application-with-no-contract-deployed-to-environments-as-any-other-and-another-application-reaches-it-only-once-the-service-s-side-agrees.md),
  [D-51](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0051-ehos-yaml-is-defined-by-ehos.md)).

  A utility service has no contract, so nothing writes its manifest but its file: every key of the
  file as the file has it, `schema` set to `ehos.manifest/v9`, the first manifest version that
  takes `ehos.yaml/v8`, and `ehos_yaml` set to the file's own version. Nothing is added for what it
  offers, since it offers nothing. The bytes are those eh-os's
  `Ehos.Applications.EhosYaml.service_manifest/1` writes from the same file: compact JSON with each
  mapping's keys in order (eh-os [`docs/manifest.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/manifest.md),
  `ehos.manifest/v9`).

  The file is read with `Ehosctl.ServiceYaml.Reader` and checked against `ehos.yaml/v8` with
  `Ehosctl.ServiceYaml.Schema`, so a key a utility service may not give is refused with EHOS's
  reason. EHOS's own check still decides: what it checks beside the schema is not checked here.
  """

  alias Ehosctl.Refusal
  alias Ehosctl.ServiceYaml.Reader
  alias Ehosctl.ServiceYaml.Schema

  @manifest_version "ehos.manifest/v9"
  # EHOS reads at most this much of an `ehos.yaml`.
  @max_bytes 65_536
  @max_errors 50
  @max_length 256
  @max_key 64

  @typedoc """
  A utility service's file, read: `application`, its name, and `manifest`, the bytes of its
  application manifest.
  """
  @type t :: %{application: String.t(), manifest: binary()}

  @doc """
  The utility service `text`, an `ehos.yaml`, describes, with its manifest, or every reason the file
  is refused, each `line N, path: reason` as EHOS says it: at most 50, sorted by line, then one
  more saying how many are not listed.

      iex> {:ok, service} =
      ...>   Ehosctl.ServiceYaml.read(\"""
      ...>   schema: ehos.yaml/v8
      ...>   kind: service
      ...>   application: invoice-pdf
      ...>   health: {port: 8081, ready: /ready, live: /live}
      ...>   \""")
      iex> service.manifest
      ~s({"application":"invoice-pdf","ehos_yaml":"ehos.yaml/v8","health":{"live":"/live","port":8081,"ready":"/ready"},"kind":"service","schema":"ehos.manifest/v9"})
  """
  @spec read(binary()) :: {:ok, t()} | {:error, [String.t()]}
  def read(text) when byte_size(text) > @max_bytes,
    do:
      refused([error([], "the file is #{byte_size(text)} bytes; at most #{@max_bytes} are read")])

  def read(text) do
    case Reader.decode(text) do
      {:ok, data, lines} -> checked(data, lines)
      {:error, errors} -> refused(errors)
    end
  end

  @doc "The most bytes of an `ehos.yaml` EHOS reads, and `read/1` reads."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  The reasons `read/1` gives, one a line, each indented and shown as a terminal may print it.

      iex> Ehosctl.ServiceYaml.listed(["line 2, kind: must be service", "line 3: an alias"])
      "  - line 2, kind: must be service\\n  - line 3: an alias"
  """
  @spec listed([String.t()]) :: String.t()
  def listed(reasons), do: Enum.map_join(reasons, "\n", &("  - " <> Refusal.shown(&1)))

  defp checked(data, lines) do
    with :ok <- version(data),
         {:ok, valid} <- Schema.validate(data),
         :ok <- a_service(valid) do
      {:ok,
       %{
         application: Map.fetch!(valid, "application"),
         manifest:
           data
           |> Map.put("schema", @manifest_version)
           |> Map.put("ehos_yaml", Schema.version())
           |> JSON.encode!()
       }}
    else
      {:error, errors} -> refused(errors, lines)
    end
  end

  # Only `ehos.yaml/v8` and later say `kind`, so an earlier version is an application's; a later
  # one is beyond what this ehosctl knows.
  defp version(%{"schema" => version}) do
    if version == Schema.version(),
      do: :ok,
      else: {:error, [error(["schema"], not_v8(version))]}
  end

  defp version(%{}),
    do:
      {:error,
       [
         error(
           ["schema"],
           "is required: it names the version the file is written in, #{Schema.version()}"
         )
       ]}

  defp version(_other), do: {:error, [error([], "the file must be a mapping of keys to values")]}

  defp not_v8(version) when is_binary(version),
    do:
      "is #{version}, and ehosctl reads a utility service's file in #{Schema.version()}, the " <>
        "first version that says kind: service"

  defp not_v8(_version), do: "must be a string naming a version, such as #{Schema.version()}"

  defp a_service(%{"kind" => "service"}), do: :ok

  defp a_service(_application),
    do:
      {:error,
       [
         error(
           [],
           "the file is an application's, whose manifest eh-os-contract writes from its " <>
             "contracts: say kind: service in a utility service's file"
         )
       ]}

  defp refused(errors, lines \\ %{}) do
    {:error,
     errors
     |> Enum.map(fn error ->
       %{
         path: error.path |> path() |> cut(@max_length),
         line: error.line || line(lines, error.path),
         message: cut(error.message, @max_length)
       }
     end)
     |> Enum.uniq()
     |> Enum.sort_by(&{&1.line || 0, &1.path, &1.message})
     |> at_most()
     |> Enum.map(&said/1)}
  end

  # A reason gets the line of its value or, for a key that is missing, of the nearest value
  # around it.
  defp line(lines, path) do
    case Map.fetch(lines, path) do
      {:ok, line} -> line
      :error when path == [] -> nil
      :error -> line(lines, Enum.drop(path, -1))
    end
  end

  defp at_most(errors) do
    case Enum.split(errors, @max_errors) do
      {listed, []} -> listed
      {listed, rest} -> listed ++ [%{path: "", line: nil, message: more(length(rest))}]
    end
  end

  defp more(1), do: "and 1 more reason, not listed"
  defp more(count), do: "and #{count} more reasons, not listed"

  defp said(%{line: nil, path: "", message: message}), do: message
  defp said(%{line: nil, path: path, message: message}), do: "#{path}: #{message}"
  defp said(%{line: line, path: "", message: message}), do: "line #{line}: #{message}"
  defp said(%{line: line, path: path, message: message}), do: "line #{line}, #{path}: #{message}"

  # Written as a reader would look for it, `serves[1].port`; a key that could be read as more
  # than one, or as nothing, is quoted as JSON writes it, in brackets: `["a.b"]`.
  defp path(path) do
    Enum.reduce(path, "", fn
      index, written when is_integer(index) -> "#{written}[#{index}]"
      key, written -> join(written, cut(key, @max_key))
    end)
  end

  defp join(written, key) do
    cond do
      not Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_-]*\z/, key) -> "#{written}[#{JSON.encode!(key)}]"
      written == "" -> key
      true -> "#{written}.#{key}"
    end
  end

  # At most `max` code points, the last an ellipsis when the text is longer, as EHOS cuts it.
  defp cut(text, max) do
    points = String.codepoints(text)

    if length(points) <= max,
      do: text,
      else: Enum.join(Enum.take(points, max - 1)) <> "…"
  end

  defp error(path, message), do: %{path: path, line: nil, message: message}
end
