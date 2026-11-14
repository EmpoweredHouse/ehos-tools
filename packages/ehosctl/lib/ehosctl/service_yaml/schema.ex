defmodule Ehosctl.ServiceYaml.Schema do
  @moduledoc """
  A document checked against `ehos.yaml/v8`, its JSON Schema, with each reason in EHOS's words
  (eh-os D-51).

  The schema is EHOS's file, carried in `priv/schemas/ehos.yaml/v8.json` and compiled in, so the
  check works offline; a test pins it to EHOS's bytes, as eh-os D-111 asks of every copy. What JSV
  finds is said as eh-os's `Ehos.Applications.EhosYaml.Schema` says it, each reason at the path of
  the value it is about, and in the words `EhosYaml.V1` to `V8` give for a place in the schema:
  for a key a utility service may not give, the reason and what to do. The rules EHOS checks
  beside the schema, such as two entries of `serves` on one port, are EHOS's alone: `ehosctl
  verify` asks EHOS for them when the person is signed in.
  """

  alias Ehosctl.ServiceYaml.Reader

  @version "ehos.yaml/v8"
  @file_path Path.expand("../../../priv/schemas/ehos.yaml/v8.json", __DIR__)
  @external_resource @file_path
  @document File.read!(@file_path)
  @schema JSON.decode!(@document)

  # What failed inside a value is reported there; these report it again at every value around it.
  @enclosing [:properties, :items, :additionalProperties, :"$ref", :allOf]

  # Each place of the schema EHOS gives words for, in the words of the version that added it.
  @words %{
    # v1
    "#/$defs/port" => "must be an integer from 1024 to 65535",
    "#/$defs/path" =>
      "must be an HTTP path: a slash, then printable ASCII without spaces, 256 characters at most",
    "#/$defs/serve/properties/name" =>
      "must be at most 15 lowercase letters, digits and single dashes, starting with a letter " <>
        "and not ending with a dash",
    "#/properties/application" =>
      "must be lowercase letters, digits and dashes, starting with a letter and not ending with " <>
        "a dash, 63 characters at most",
    "#/properties/application/not" => "is the platform's own namespace",
    "#/properties/needs/properties/database/properties/version" =>
      "must be a PostgreSQL major version, such as 16, or a lowest one, such as \">= 16\"",
    # v2
    "#/$defs/application" =>
      "must be lowercase letters, digits and dashes, starting with a letter and not ending " <>
        "with a dash, 63 characters at most",
    "#/$defs/application/not" => "is the platform's own namespace",
    "#/properties/sign_in/properties/applications" =>
      "must name each application once, at most 16 of them",
    # v3
    "#/properties/needs/properties/people" => "must be read, the one way to need the people",
    # v4
    "#/$defs/secret/properties/name" =>
      "must be a lowercase word of at most 63 letters, digits and underscores, starting with a " <>
        "letter",
    "#/$defs/secret/properties/name/not" =>
      "is a name EHOS gives every workload or the runtime reads or sets in every container " <>
        "(ehos_*, database_*, phx_*, otel_*, pg*, release_*, erl_*, elixir_*, ld_*, lc_*, " <>
        "kubernetes_*, secret_key_base, path, home, hostname, lang, shell, user, tmpdir)",
    "#/$defs/secret/properties/version" => "must be a version, an integer from 1 to 2147483647",
    "#/properties/needs/properties/secrets" => "must list at most 32 secrets",
    # v5
    "#/$defs/egress/properties/host" =>
      "must be a host's DNS name in lowercase, such as registry.example.org, of at most 253 " <>
        "characters: never an address, and never a pattern",
    "#/$defs/egress/properties/port" => "must be a port, an integer from 1 to 65535",
    "#/properties/needs/properties/egress" => "must list at most 32 hosts",
    # v6
    "#/$defs/reply_domain" =>
      "must be a domain's DNS name in lowercase, such as reply.office.example.org, of at most " <>
        "253 characters: never an address, and never a pattern",
    "#/properties/needs/properties/mail/properties/level" =>
      "must be internal, to people in EHOS's directory only, or external, to any address as well",
    "#/properties/needs/properties/mail/properties/reply_domains" =>
      "must list at most 8 domains",
    # v7
    "#/properties/needs/properties/compute" => "must name cpu, memory or both",
    "#/properties/needs/properties/compute/properties/cpu" =>
      "must be CPU as a quantity of at most 20 characters: 250m for a quarter of a core, or 1 " <>
        "or 1.5 for whole cores",
    "#/properties/needs/properties/compute/properties/memory" =>
      "must be memory as a whole number of bytes with a suffix, of at most 20 characters: " <>
        "512Mi or 1Gi",
    # v8: what a utility service may not give, each with why and what to do.
    "#/then" =>
      "is required for a utility service, which has no contract to take its name from: name " <>
        "the service here",
    "#/then/properties/needs/properties/database" =>
      "is not for a utility service, which keeps no data of its own: remove it",
    "#/then/properties/needs/properties/people" =>
      "is not for a utility service, which does not read the people directory: remove it",
    "#/then/properties/needs/properties/mail" =>
      "is not for a utility service, which sends no mail through EHOS: remove it",
    "#/then/properties/needs/properties/services" =>
      "is not for a utility service, which calls no other utility service: remove it",
    "#/then/properties/sign_in" =>
      "is not for a utility service, which signs nobody in: remove it",
    "#/then/properties/serves/items/properties/public/not" =>
      "must not be true for a utility service: only the applications of its environment " <>
        "reach it, each with a service agreement",
    "#/properties/kind" =>
      "must be application, a workload with a contract, or service, a utility service",
    "#/properties/needs/properties/services" => "must list at most 16 utility services"
  }

  @doc "The version this module checks a document against: `ehos.yaml/v8`."
  @spec version() :: String.t()
  def version, do: @version

  @doc "The schema's file, byte for byte as EHOS serves it at `/schemas/ehos.yaml/v8.json`."
  @spec document() :: String.t()
  def document, do: @document

  @doc """
  `data` as the schema takes it, or every reason it is refused, each at the path of the value it
  is about, with no line: the caller knows the lines of its file.
  """
  @spec validate(term()) :: {:ok, term()} | {:error, [Reader.error()]}
  def validate(data) do
    case JSV.validate(data, root()) do
      {:ok, valid} ->
        {:ok, valid}

      {:error, error} ->
        {:error,
         error
         |> JSV.normalize_error()
         |> Map.fetch!(:details)
         |> Enum.flat_map(&reasons(&1, data))
         |> Enum.uniq()}
    end
  end

  # Built once per run: a check is one file. With each pattern's `$` ending the text, as JSON
  # Schema means it, where PCRE's would also match before a final line break (eh-os#893).
  defp root, do: @schema |> ecma() |> JSV.build!()

  defp reasons(unit, data) do
    path = from_pointer(unit.instanceLocation, data)
    here = resolve(unit.schemaLocation)
    own = Map.get(@words, unit.schemaLocation)
    Enum.flat_map(unit.errors, &reason_of(&1, unit, data, path, here, own))
  end

  # What a schema's `then` refuses is said by what failed inside it; the `if` that held is listed
  # with it, and failed nothing.
  defp reason_of(%{kind: :"if/then", details: details}, _unit, data, _path, _here, _own) do
    details
    |> Enum.reject(& &1.valid)
    |> Enum.flat_map(&reasons(&1, data))
  end

  defp reason_of(%{kind: kind}, _unit, _data, _path, _here, _own) when kind in @enclosing,
    do: []

  defp reason_of(%{kind: :required}, _unit, data, path, here, own),
    do: missing(here, value_at(data, path), path, own || "is required")

  # A value of the wrong type is told its type: a version written as 16, a number, is not told
  # that 16 is an example of what it should be.
  defp reason_of(%{kind: kind}, _unit, _data, path, _here, own)
       when own != nil and kind != :type,
       do: [error(path, own)]

  defp reason_of(%{kind: :boolean_schema, message: message}, unit, _data, path, _here, _own),
    do: [error(path, unknown(unit.evaluationPath, message))]

  defp reason_of(%{kind: kind, message: message}, _unit, _data, path, here, _own),
    do: [error(path, reason(kind, here, message))]

  # Each missing key is reported where it should be.
  defp missing(%{"required" => required}, %{} = present, path, message) do
    for key <- required, not Map.has_key?(present, key), do: error(path ++ [key], message)
  end

  defp missing(_here, _present, _path, _message), do: []

  # `additionalProperties: false` is the one schema of `false` the version has but the utility
  # service's, which have words of their own: a key it does not know.
  defp unknown(evaluation_path, message) do
    if String.ends_with?(evaluation_path, "/additionalProperties"),
      do: "is not a field of #{@version}",
      else: message
  end

  defp reason(:type, %{"type" => type}, _message), do: "must be #{a(type)}"
  defp reason(:const, %{"const" => value}, _message), do: "must be #{value}"
  defp reason(:enum, %{"enum" => values}, _message), do: "must be #{Enum.join(values, " or ")}"
  defp reason(:pattern, %{"pattern" => pattern}, _message), do: "must match #{pattern}"
  defp reason(:minimum, %{"minimum" => min}, _message), do: "must be at least #{min}"
  defp reason(:maximum, %{"maximum" => max}, _message), do: "must be at most #{max}"

  defp reason(:minLength, %{"minLength" => min}, _message),
    do: "must be at least #{min} #{characters(min)} long"

  defp reason(:maxLength, %{"maxLength" => max}, _message),
    do: "must be at most #{max} #{characters(max)} long"

  defp reason(:minItems, %{"minItems" => min}, _message), do: "must list at least #{min}"
  defp reason(:maxItems, %{"maxItems" => max}, _message), do: "must list at most #{max}"
  defp reason(_kind, _here, message), do: message

  defp a("object"), do: "a mapping of keys to values"
  defp a("array"), do: "a list"
  defp a("string"), do: "a string"
  defp a("integer"), do: "an integer"
  defp a("boolean"), do: "true or false"
  defp a(type), do: "of type #{type}"

  defp characters(1), do: "character"
  defp characters(_count), do: "characters"

  # The schema's own locations: `#`, `#/$defs/port`, `#/properties/application/not`.
  defp resolve("#" <> pointer) do
    pointer
    |> String.split("/", trim: true)
    |> Enum.reduce(@schema, fn key, here -> if is_map(here), do: Map.get(here, key) end)
  end

  defp value_at(data, path) do
    Enum.reduce(path, data, fn
      index, list when is_integer(index) and is_list(list) -> Enum.at(list, index)
      key, %{} = map -> Map.get(map, key)
      _key, _other -> nil
    end)
  end

  # A JSON Pointer as JSV writes it (`#/serves/1/port`), read against the document it points
  # into, so that an index into a list is an integer and a key that looks like one is not.
  defp from_pointer("#" <> pointer, document), do: from_pointer(pointer, document)
  defp from_pointer("", _document), do: []

  defp from_pointer("/" <> pointer, document) do
    pointer
    |> String.split("/")
    |> Enum.map(&unescape/1)
    |> Enum.map_reduce(document, &segment/2)
    |> elem(0)
  end

  defp segment(token, list) when is_list(list) do
    case Integer.parse(token) do
      {index, ""} -> {index, Enum.at(list, index)}
      _other -> {token, nil}
    end
  end

  defp segment(token, %{} = map), do: {token, Map.get(map, token)}
  defp segment(token, _other), do: {token, nil}

  # RFC 6901: `~1` is `/`, then `~0` is `~`.
  defp unescape(token), do: token |> String.replace("~1", "/") |> String.replace("~0", "~")

  defp error(path, message), do: %{path: path, line: nil, message: message}

  # Each `$` that ends a pattern's text is written `\z`, as eh-os's `Ehos.JsonSchema.ecma/1`
  # writes it. What these hold is data, not schemas: a `pattern` in it is a value and stays as
  # written.
  @data ~w(const enum default examples)
  # These map names to schemas: a property named `pattern` or `default` is a schema like another.
  @named ~w(properties $defs definitions dependentSchemas)

  defp ecma(%{} = schema), do: Map.new(schema, &ecma_entry/1)
  defp ecma(list) when is_list(list), do: Enum.map(list, &ecma/1)
  defp ecma(value), do: value

  defp ecma_entry({"pattern", pattern}) when is_binary(pattern),
    do: {"pattern", anchor(pattern, <<>>, false)}

  defp ecma_entry({"patternProperties", %{} = properties}),
    do:
      {"patternProperties",
       Map.new(properties, fn {pattern, value} -> {anchor(pattern, <<>>, false), ecma(value)} end)}

  defp ecma_entry({key, %{} = schemas}) when key in @named,
    do: {key, Map.new(schemas, fn {name, value} -> {name, ecma(value)} end)}

  defp ecma_entry({key, value}) when key in @data, do: {key, value}
  defp ecma_entry({key, value}), do: {key, ecma(value)}

  # The flag is whether the walk is inside a character class, `[…]`, where only `\` and `]` mean
  # anything to it.
  defp anchor(<<?\\, char::utf8, rest::binary>>, acc, class),
    do: anchor(rest, <<acc::binary, ?\\, char::utf8>>, class)

  defp anchor(<<?[, rest::binary>>, acc, false), do: anchor(rest, <<acc::binary, ?[>>, true)
  defp anchor(<<?], rest::binary>>, acc, true), do: anchor(rest, <<acc::binary, ?]>>, false)
  defp anchor(<<?$, rest::binary>>, acc, false), do: anchor(rest, <<acc::binary, "\\z">>, false)

  defp anchor(<<char::utf8, rest::binary>>, acc, class),
    do: anchor(rest, <<acc::binary, char::utf8>>, class)

  defp anchor(<<>>, acc, _class), do: acc
end
