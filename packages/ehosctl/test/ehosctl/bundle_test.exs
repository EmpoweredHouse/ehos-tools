defmodule Ehosctl.BundleTest do
  use ExUnit.Case, async: true

  alias Ehosctl.Bundle
  alias Ehosctl.BundleFixture

  @moduletag :tmp_dir

  @manifest ~s({"schema": "ehos.manifest/v3", "application": "ledger"}\n)
  @domain ~s({"schema": "eh_os_contract.graph.v1", "kind": "domain", "label": "Księga"}\n)
  @contract ~s({"schema": "eh_os_contract.graph.v1", "kind": "contract"}\n)

  defp index!(dir), do: dir |> Path.join("bundle.json") |> File.read!() |> JSON.decode!()

  defp index!(dir, index), do: File.write!(Path.join(dir, "bundle.json"), JSON.encode!(index))

  test "reads the manifest and each graph document in the index's order, as their bytes are",
       %{tmp_dir: dir} do
    index =
      BundleFixture.write(dir, @manifest, [
        {"domain.Lending.Domain.json", @domain},
        {"contract.lending.json", @contract}
      ])

    assert {:ok, bundle} = Bundle.read(dir)
    assert bundle.index == index
    assert bundle.manifest == @manifest
    assert bundle.graphs == [@domain, @contract]
    assert bundle.graph_bytes == byte_size(@domain) + byte_size(@contract)
    assert bundle.application == "ledger"
  end

  test "refuses a file changed after the index was written", %{tmp_dir: dir} do
    BundleFixture.write(dir, @manifest, [{"domain.json", @domain}])
    File.write!(Path.join(dir, "graph/domain.json"), String.replace(@domain, "Księga", "Ksiega"))

    assert {:error, :invalid, message} = Bundle.read(dir)
    size = byte_size(@domain)

    assert message =~
             "graph/domain.json is #{size - 1} bytes, not the #{size} bundle.json gives it"

    assert message =~ "Nothing was sent."

    File.write!(Path.join(dir, "graph/domain.json"), String.replace(@domain, "domain", "dOmain"))
    assert {:error, :invalid, message} = Bundle.read(dir)
    assert message =~ "is not the file bundle.json names: its SHA-256 differs"
  end

  test "reads no file the index does not name, and none outside graph/", %{tmp_dir: dir} do
    BundleFixture.write(dir, @manifest, [{"domain.json", @domain}])

    for path <- ["../ehos.manifest.json", "graph/../bundle.json", "graph/.hidden.json", "x.json"] do
      index = index!(dir)
      index!(dir, put_in(index, ["graph"], [BundleFixture.file(path, @domain)]))

      assert {:error, :invalid, message} = Bundle.read(dir)
      assert message =~ "which is not a path in graph/", path
    end
  end

  test "refuses a link in place of a file it names", %{tmp_dir: dir} do
    BundleFixture.write(dir, @manifest, [{"domain.json", @domain}])
    outside = Path.join(dir, "outside.json")
    File.write!(outside, @domain)
    File.rm!(Path.join(dir, "graph/domain.json"))
    File.ln_s!(outside, Path.join(dir, "graph/domain.json"))

    assert {:error, :invalid, message} = Bundle.read(dir)
    assert message =~ "graph/domain.json is not a regular file (symlink)"
  end

  test "refuses an index EHOS would refuse for its form", %{tmp_dir: dir} do
    BundleFixture.write(dir, @manifest, [{"domain.json", @domain}])
    index = index!(dir)

    refused = [
      {Map.delete(index, "schema"), "names no schema"},
      {%{index | "schema" => "ehos.bundle/v2"}, "which this ehosctl does not read"},
      {put_in(index, ["manifest", "path"], "manifest.json"), "a bundle's manifest is"},
      {put_in(index, ["manifest", "sha256"], "ABC"), "not 64 lowercase hexadecimal digits"},
      {put_in(index, ["manifest", "bytes"], 0), "a file of a bundle is 1 to 1048576"},
      {%{index | "graph" => index["graph"] ++ index["graph"]}, "twice"},
      {%{
         index
         | "graph" =>
             [put_in(hd(index["graph"]), ["path"], "graph/DOMAIN.json")] ++
               index["graph"]
       }, "twice"},
      {%{index | "graph" => List.duplicate(hd(index["graph"]), 513)}, "at most 512"},
      {%{index | "graph" => nil}, "lists no graph documents as a list"}
    ]

    for {broken, said} <- refused do
      index!(dir, broken)
      assert {:error, :invalid, message} = Bundle.read(dir)
      assert message =~ said
    end

    big =
      for n <- 1..33,
          do: BundleFixture.file("graph/d#{n}.json", "x") |> Map.put("bytes", 1_048_576)

    index!(dir, %{index | "graph" => big})
    assert {:error, :invalid, message} = Bundle.read(dir)
    assert message =~ "more than 33554432 bytes in all"
  end

  test "says when the directory holds no bundle", %{tmp_dir: dir} do
    assert {:error, :invalid, message} = Bundle.read(Path.join(dir, "none"))
    assert message =~ "bundle.json does not exist: is it a bundle's directory?"
  end

  test "refuses a manifest that names no application", %{tmp_dir: dir} do
    BundleFixture.write(dir, ~s({"schema": "ehos.manifest/v3"}), [])
    assert {:error, :invalid, message} = Bundle.read(dir)
    assert message =~ "ehos.manifest.json names no application"
  end
end
