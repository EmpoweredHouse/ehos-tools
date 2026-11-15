defmodule Ehosctl.BundleTest do
  use Ehosctl.Case, async: true

  alias Ehosctl.Bundle
  alias Ehosctl.BundleFixture

  @moduletag :tmp_dir

  @manifest ~s({"schema": "ehos.manifest/v3", "application": "ledger"}\n)
  @domain ~s({"schema": "eh_os_contract.graph.v1", "kind": "domain", "label": "Księga"}\n)
  @contract ~s({"schema": "eh_os_contract.graph.v1", "kind": "contract"}\n)
  @graph_path "A path is a letter or digit, then letters, digits, ., _ or -, and ends in .json."

  doctest Bundle, only: [index: 2]

  describe "write/2" do
    test "writes a bundle of the manifest alone, which read/1 reads back", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "_build/ehos.bundle")

      assert Bundle.write(dir, @manifest) == :ok

      assert Bundle.read(dir) ==
               {:ok,
                %{
                  index: Bundle.index(@manifest),
                  manifest: @manifest,
                  graphs: [],
                  graph_bytes: 0,
                  openapi: nil,
                  application: "ledger"
                }}
    end

    test "writes a bundle of the manifest and an OpenAPI file as v2, which read/1 reads back",
         %{tmp_dir: tmp} do
      dir = Path.join(tmp, "_build/ehos.bundle")
      openapi = %{path: "openapi.yaml", bytes: "openapi: 3.1.0\n"}

      assert Bundle.write(dir, @manifest, openapi) == :ok
      assert File.read!(Path.join(dir, "openapi.yaml")) == "openapi: 3.1.0\n"

      assert Bundle.read(dir) ==
               {:ok,
                %{
                  index: Bundle.index(@manifest, openapi),
                  manifest: @manifest,
                  graphs: [],
                  graph_bytes: 0,
                  openapi: openapi,
                  application: "ledger"
                }}

      assert JSON.decode!(Bundle.index(@manifest, openapi))["schema"] == "ehos.bundle/v2"
    end

    test "writes through no link left where a file goes", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "bundle")
      target = Path.join(tmp, "kept")
      File.write!(target, "kept")
      File.mkdir_p!(dir)
      File.ln_s!(target, Path.join(dir, "ehos.manifest.json"))

      assert Bundle.write(dir, @manifest) ==
               {:error, :failed,
                "#{dir}/ehos.manifest.json: ehosctl cannot write it (file already exists)."}

      assert File.read!(target) == "kept"
    end
  end

  describe "read/1" do
    test "reads the manifest and each graph document in the index's order, as their bytes are",
         %{tmp_dir: dir} do
      index =
        BundleFixture.write(dir, @manifest, [
          {"domain.Lending.Domain.json", @domain},
          {"contract.lending.json", @contract}
        ])

      assert Bundle.read(dir) ==
               {:ok,
                %{
                  index: index,
                  manifest: @manifest,
                  graphs: [@domain, @contract],
                  graph_bytes: byte_size(@domain) + byte_size(@contract),
                  openapi: nil,
                  application: "ledger"
                }}
    end

    test "refuses a file changed after the index was written", %{tmp_dir: dir} do
      BundleFixture.write(dir, @manifest, [{"domain.json", @domain}])
      file = Path.join(dir, "graph/domain.json")
      File.write!(file, String.replace(@domain, "Księga", "Ksiega"))
      size = byte_size(@domain)

      assert Bundle.read(dir) ==
               {:error, :invalid,
                "#{file} is #{size - 1} bytes, but bundle.json gives #{size} bytes. The bundle " <>
                  "changed after it was written. ehosctl sent nothing."}

      File.write!(file, String.replace(@domain, "domain", "dOmain"))

      assert Bundle.read(dir) ==
               {:error, :invalid,
                "#{file} is not the file that bundle.json names: its SHA-256 differs. The " <>
                  "bundle changed after it was written. ehosctl sent nothing."}
    end

    test "reads no file the index does not name, and none outside graph/", %{tmp_dir: dir} do
      BundleFixture.write(dir, @manifest, [{"domain.json", @domain}])

      for path <- [
            "../ehos.manifest.json",
            "graph/../bundle.json",
            "graph/.hidden.json",
            "x.json"
          ] do
        index = index!(dir)
        index!(dir, put_in(index, ["graph"], [BundleFixture.file(path, @domain)]))

        assert Bundle.read(dir) ==
                 {:error, :invalid,
                  "#{dir}/bundle.json names the graph document #{path}, which is not a path in " <>
                    "graph/. #{@graph_path} ehosctl sent nothing."}
      end
    end

    test "refuses a link in place of a file it names", %{tmp_dir: dir} do
      BundleFixture.write(dir, @manifest, [{"domain.json", @domain}])
      outside = Path.join(dir, "outside.json")
      File.write!(outside, @domain)
      File.rm!(Path.join(dir, "graph/domain.json"))
      File.ln_s!(outside, Path.join(dir, "graph/domain.json"))

      assert Bundle.read(dir) ==
               {:error, :invalid,
                "#{dir}/graph/domain.json is not a regular file (symlink). ehosctl sent nothing."}
    end

    test "reads no graph document through a linked graph/", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "bundle")
      elsewhere = Path.join(tmp_dir, "elsewhere")
      BundleFixture.write(dir, @manifest, [{"domain.json", @domain}])
      File.rename!(Path.join(dir, "graph"), elsewhere)
      File.ln_s!(elsewhere, Path.join(dir, "graph"))

      assert Bundle.read(dir) ==
               {:error, :invalid,
                "#{dir}/graph is not a directory (symlink). ehosctl sent nothing."}
    end

    test "refuses an index EHOS would refuse for its form", %{tmp_dir: dir} do
      BundleFixture.write(dir, @manifest, [{"domain.json", @domain}])
      index = index!(dir)
      where = "#{dir}/bundle.json"

      refused = [
        {Map.delete(index, "schema"),
         "#{where} is not the index of a bundle: it does not name the schema ehos.bundle/v1 " <>
           "or ehos.bundle/v2."},
        {%{index | "schema" => "ehos.bundle/v3"},
         "#{where} has the schema \"ehos.bundle/v3\". This ehosctl reads only " <>
           "ehos.bundle/v1 and ehos.bundle/v2."},
        {Map.put(index, "openapi", index["manifest"]),
         "#{where} names an OpenAPI file, which only an index of the schema ehos.bundle/v2 " <>
           "holds."},
        {Map.merge(index, %{
           "schema" => "ehos.bundle/v2",
           "openapi" => %{index["manifest"] | "path" => "api.yaml"}
         }),
         "#{where} names the OpenAPI file api.yaml, but an OpenAPI file of a bundle is " <>
           "openapi.json, openapi.yaml, openapi.yml."},
        {Map.merge(index, %{
           "schema" => "ehos.bundle/v2",
           "openapi" => %{index["manifest"] | "path" => "openapi.yaml", "sha256" => "x"}
         }),
         "#{where} gives the OpenAPI file a SHA-256 that is not 64 lowercase hexadecimal " <>
           "digits."},
        {put_in(index, ["manifest", "path"], "manifest.json"),
         "#{where} names the application manifest manifest.json, but the application " <>
           "manifest of a bundle is ehos.manifest.json."},
        {put_in(index, ["manifest", "sha256"], "ABC"),
         "#{where} gives manifest a SHA-256 that is not 64 lowercase hexadecimal digits."},
        {put_in(index, ["manifest", "bytes"], 0),
         "#{where} gives manifest 0 bytes. A file of a bundle has 1 to 1048576 bytes."},
        {%{index | "graph" => index["graph"] ++ index["graph"]},
         "#{where} names graph/domain.json twice."},
        {%{
           index
           | "graph" =>
               [put_in(hd(index["graph"]), ["path"], "graph/DOMAIN.json")] ++
                 index["graph"]
         }, "#{where} names graph/domain.json twice."},
        {%{index | "graph" => List.duplicate(hd(index["graph"]), 513)},
         "#{where} lists 513 graph documents, and a bundle holds at most 512."},
        {%{index | "graph" => nil}, "#{where} does not give the graph documents as a list."}
      ]

      for {broken, said} <- refused do
        index!(dir, broken)
        assert Bundle.read(dir) == {:error, :invalid, said <> " ehosctl sent nothing."}
      end

      big =
        for n <- 1..33,
            do: BundleFixture.file("graph/d#{n}.json", "x") |> Map.put("bytes", 1_048_576)

      index!(dir, %{index | "graph" => big})

      assert Bundle.read(dir) ==
               {:error, :invalid,
                "#{where} lists graph documents of more than 33554432 bytes in all. " <>
                  "ehosctl sent nothing."}
    end

    test "says when the directory holds no bundle", %{tmp_dir: dir} do
      assert Bundle.read(Path.join(dir, "none")) ==
               {:error, :invalid,
                "#{dir}/none/bundle.json does not exist. Give the directory of a bundle. " <>
                  "ehosctl sent nothing."}
    end

    test "refuses a manifest that names no application", %{tmp_dir: dir} do
      BundleFixture.write(dir, ~s({"schema": "ehos.manifest/v3"}), [])

      assert Bundle.read(dir) ==
               {:error, :invalid,
                "#{dir}/ehos.manifest.json is not an application manifest: it does not name an " <>
                  "application. ehosctl sent nothing."}
    end
  end

  defp index!(dir), do: dir |> Path.join("bundle.json") |> File.read!() |> JSON.decode!()

  defp index!(dir, index), do: File.write!(Path.join(dir, "bundle.json"), JSON.encode!(index))
end
