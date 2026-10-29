defmodule Ehosctl.BundleTest do
  use Ehosctl.Case, async: true

  alias Ehosctl.Bundle
  alias Ehosctl.BundleFixture

  @moduletag :tmp_dir

  @manifest ~s({"schema": "ehos.manifest/v3", "application": "ledger"}\n)
  @domain ~s({"schema": "eh_os_contract.graph.v1", "kind": "domain", "label": "Księga"}\n)
  @contract ~s({"schema": "eh_os_contract.graph.v1", "kind": "contract"}\n)
  @graph_path "a letter or digit, then letters, digits, ., _ or -, ending in .json."

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
                "#{file} is #{size - 1} bytes, not the #{size} bundle.json gives it: the " <>
                  "bundle was changed after it was written. Nothing was sent."}

      File.write!(file, String.replace(@domain, "domain", "dOmain"))

      assert Bundle.read(dir) ==
               {:error, :invalid,
                "#{file} is not the file bundle.json names: its SHA-256 differs, so the bundle " <>
                  "was changed after it was written. Nothing was sent."}
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
                    "graph/: #{@graph_path} Nothing was sent."}
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
                "#{dir}/graph/domain.json is not a regular file (symlink). Nothing was sent."}
    end

    test "reads no graph document through a linked graph/", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "bundle")
      elsewhere = Path.join(tmp_dir, "elsewhere")
      BundleFixture.write(dir, @manifest, [{"domain.json", @domain}])
      File.rename!(Path.join(dir, "graph"), elsewhere)
      File.ln_s!(elsewhere, Path.join(dir, "graph"))

      assert Bundle.read(dir) ==
               {:error, :invalid, "#{dir}/graph is not a directory (symlink). Nothing was sent."}
    end

    test "refuses an index EHOS would refuse for its form", %{tmp_dir: dir} do
      BundleFixture.write(dir, @manifest, [{"domain.json", @domain}])
      index = index!(dir)
      where = "#{dir}/bundle.json"

      refused = [
        {Map.delete(index, "schema"),
         "#{where} names no schema, so it is not a bundle's index (ehos.bundle/v1)."},
        {%{index | "schema" => "ehos.bundle/v2"},
         "#{where} is \"ehos.bundle/v2\", which this ehosctl does not read: it reads " <>
           "ehos.bundle/v1."},
        {put_in(index, ["manifest", "path"], "manifest.json"),
         "#{where} names the manifest manifest.json; a bundle's manifest is ehos.manifest.json."},
        {put_in(index, ["manifest", "sha256"], "ABC"),
         "#{where} gives manifest a SHA-256 that is not 64 lowercase hexadecimal digits."},
        {put_in(index, ["manifest", "bytes"], 0),
         "#{where} gives manifest 0 bytes; a file of a bundle is 1 to 1048576."},
        {%{index | "graph" => index["graph"] ++ index["graph"]},
         "#{where} names graph/domain.json twice."},
        {%{
           index
           | "graph" =>
               [put_in(hd(index["graph"]), ["path"], "graph/DOMAIN.json")] ++
                 index["graph"]
         }, "#{where} names graph/domain.json twice."},
        {%{index | "graph" => List.duplicate(hd(index["graph"]), 513)},
         "#{where} lists 513 graph documents; a bundle holds at most 512."},
        {%{index | "graph" => nil}, "#{where} lists no graph documents as a list."}
      ]

      for {broken, said} <- refused do
        index!(dir, broken)
        assert Bundle.read(dir) == {:error, :invalid, said <> " Nothing was sent."}
      end

      big =
        for n <- 1..33,
            do: BundleFixture.file("graph/d#{n}.json", "x") |> Map.put("bytes", 1_048_576)

      index!(dir, %{index | "graph" => big})

      assert Bundle.read(dir) ==
               {:error, :invalid,
                "#{where} lists graph documents of more than 33554432 bytes in all. " <>
                  "Nothing was sent."}
    end

    test "says when the directory holds no bundle", %{tmp_dir: dir} do
      assert Bundle.read(Path.join(dir, "none")) ==
               {:error, :invalid,
                "#{dir}/none/bundle.json does not exist: is it a bundle's directory? " <>
                  "Nothing was sent."}
    end

    test "refuses a manifest that names no application", %{tmp_dir: dir} do
      BundleFixture.write(dir, ~s({"schema": "ehos.manifest/v3"}), [])

      assert Bundle.read(dir) ==
               {:error, :invalid,
                "#{dir}/ehos.manifest.json names no application, so it is not a manifest. " <>
                  "Nothing was sent."}
    end
  end

  defp index!(dir), do: dir |> Path.join("bundle.json") |> File.read!() |> JSON.decode!()

  defp index!(dir, index), do: File.write!(Path.join(dir, "bundle.json"), JSON.encode!(index))
end
