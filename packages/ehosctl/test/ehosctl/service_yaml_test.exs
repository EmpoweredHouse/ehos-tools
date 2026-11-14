defmodule Ehosctl.ServiceYamlTest do
  # A utility service's ehos.yaml read as EHOS reads it, and its manifest written as EHOS writes
  # it (ehos-tools#917, eh-os D-175).
  use ExUnit.Case, async: true

  alias Ehosctl.ServiceYaml
  alias Ehosctl.ServiceYaml.Schema

  doctest ServiceYaml

  # eh-os D-111: every copy of a version of the schema is EHOS's file, held to its bytes. This is
  # the SHA-256 of eh-os's `priv/schemas/ehos.yaml/v8.json`.
  @v8_sha256 "b9d8a7ffcc287656ce9c5e14b1aa0abf826d4b432b35ab05a07e22ca151e66f8"

  @health "health: {port: 8081, ready: /ready, live: /live}\n"

  test "the schema is EHOS's ehos.yaml/v8, byte for byte" do
    assert :crypto.hash(:sha256, Schema.document()) |> Base.encode16(case: :lower) == @v8_sha256
    assert JSON.decode!(Schema.document())["title"] == "ehos.yaml/v8"
  end

  describe "read/1" do
    test "writes every key of the file as the file has it, the schema and the file's version" do
      text = """
      schema: ehos.yaml/v8
      kind: service
      application: invoice-pdf
      serves: [{name: http, port: 8080}, {name: grpc, port: 9090, public: false}]
      health: {port: 8081, ready: /ready, live: /live}
      needs:
        compute: {cpu: "1.5", memory: 512Mi}
        secrets: [{name: api_key}, {name: other_key, version: 3}]
        egress: [{host: registry.example.org}, {host: api.example.org, port: 8443}]
      """

      # As eh-os's `EhosYaml.service_manifest/1` writes it from the same file.
      assert ServiceYaml.read(text) ==
               {:ok,
                %{
                  application: "invoice-pdf",
                  manifest:
                    ~s({"application":"invoice-pdf","ehos_yaml":"ehos.yaml/v8","health":{"live":"/live","port":8081,"ready":"/ready"},"kind":"service","needs":{"compute":{"cpu":"1.5","memory":"512Mi"},"egress":[{"host":"registry.example.org"},{"host":"api.example.org","port":8443}],"secrets":[{"name":"api_key"},{"name":"other_key","version":3}]},"schema":"ehos.manifest/v9","serves":[{"name":"http","port":8080},{"name":"grpc","port":9090,"public":false}]})
                }}
    end

    test "says each value of the wrong form in EHOS's words, at its line" do
      text = """
      schema: ehos.yaml/v8
      kind: services
      application: Invoice_PDF
      health: {port: 80, ready: ready, live: 5}
      bogus: 1
      """

      assert ServiceYaml.read(text) ==
               {:error,
                [
                  "line 2, kind: must be application, a workload with a contract, or service, " <>
                    "a utility service",
                  "line 3, application: must be lowercase letters, digits and dashes, starting " <>
                    "with a letter and not ending with a dash, 63 characters at most",
                  "line 4, health.live: must be a string",
                  "line 4, health.port: must be an integer from 1024 to 65535",
                  "line 4, health.ready: must be an HTTP path: a slash, then printable ASCII " <>
                    "without spaces, 256 characters at most",
                  "line 5, bogus: is not a field of ehos.yaml/v8"
                ]}
    end

    test "refuses what JSON cannot say" do
      assert ServiceYaml.read("schema: ehos.yaml/v8\nkind: service\nhealth: &h {port: 1}\n") ==
               {:error, ["line 3: an anchor (&h) is refused: ehos.yaml holds only what JSON can"]}

      assert ServiceYaml.read("schema: ehos.yaml/v8\nkind: service\nkind: service\n" <> @health) ==
               {:error, ["line 3, kind: is given twice in one mapping; the first is on line 2"]}

      assert ServiceYaml.read("schema: ehos.yaml/v8\n---\nkind: service\n") ==
               {:error, ["line 2: the file holds more than one YAML document"]}
    end

    test "refuses an application's file, and a version before kind" do
      assert ServiceYaml.read("schema: ehos.yaml/v8\napplication: a\n" <> @health) ==
               {:error,
                [
                  "line 1: the file is an application's, whose manifest eh-os-contract writes " <>
                    "from its contracts: say kind: service in a utility service's file"
                ]}

      assert ServiceYaml.read("schema: ehos.yaml/v7\n" <> @health) ==
               {:error,
                [
                  "line 1, schema: is ehos.yaml/v7, and ehosctl reads a utility service's file " <>
                    "in ehos.yaml/v8, the first version that says kind: service"
                ]}

      assert ServiceYaml.read(@health) ==
               {:error,
                [
                  "line 1, schema: is required: it names the version the file is written in, " <>
                    "ehos.yaml/v8"
                ]}

      assert ServiceYaml.read("- a\n") ==
               {:error, ["line 1: the file must be a mapping of keys to values"]}
    end

    test "reads no file larger than EHOS reads" do
      assert ServiceYaml.read(String.duplicate("#", 65_537)) ==
               {:error, ["the file is 65537 bytes; at most 65536 are read"]}
    end
  end
end
