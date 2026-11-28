defmodule EhosRelease.MixLockTest do
  use ExUnit.Case, async: true

  alias EhosRelease.MixLock

  @lock """
  %{
    "ehos_platform": {:git, "https://github.com/EmpoweredHouse/ehos-tools.git", "9ad10977a6420542e2946ee6cd52a37cf3a17a1e", [sparse: "packages/ehos_platform", ref: "9ad10977a6420542e2946ee6cd52a37cf3a17a1e"]},
    "heroicons": {:git, "https://github.com/tailwindlabs/heroicons.git", "0435d4ca364a608cc75e2f8683d374e55abbae26", [tag: "v2.2.0", sparse: "optimized", depth: 1]},
    "req": {:hex, :req, "0.7.5", "0c32", [:mix], [{:finch, "~> 0.21", [hex: :finch, repo: "hexpm", optional: false]}], "hexpm", "5768"},
  }
  """

  test "reads a lock's git dependencies with their options" do
    {:ok, entries} = MixLock.parse(@lock)

    assert MixLock.git_dependencies(entries) == [
             {"ehos_platform", "https://github.com/EmpoweredHouse/ehos-tools.git",
              "9ad10977a6420542e2946ee6cd52a37cf3a17a1e",
              %{
                "sparse" => "packages/ehos_platform",
                "ref" => "9ad10977a6420542e2946ee6cd52a37cf3a17a1e"
              }},
             {"heroicons", "https://github.com/tailwindlabs/heroicons.git",
              "0435d4ca364a608cc75e2f8683d374e55abbae26",
              %{"tag" => "v2.2.0", "sparse" => "optimized", "depth" => 1}}
           ]
  end

  test "reads a lock full of names no atom has, and creates none" do
    names =
      for n <- 1..50, do: "ehos_release_never_an_atom_#{n}_#{System.unique_integer([:positive])}"

    lock =
      "%{" <>
        Enum.map_join(names, ", ", &~s("#{&1}": {:#{&1}, #{&1}_key: :#{&1}_value})) <> "}"

    assert {:ok, entries} = MixLock.parse(lock)
    assert map_size(entries) == 50

    for name <- names, suffix <- ["", "_key", "_value"] do
      assert_raise ArgumentError, fn -> String.to_existing_atom(name <> suffix) end
    end
  end

  test "refuses a lock that would run code, or names a variable" do
    assert MixLock.parse(~s[%{"a": File.rm_rf!("/")}]) ==
             {:error, "mix.lock holds something other than literals"}

    assert MixLock.parse(~s(%{"a": some_variable})) ==
             {:error, "mix.lock holds something other than literals"}

    assert MixLock.parse("%{") == {:error, "mix.lock is not valid Elixir"}
    assert MixLock.parse("[1, 2]") == {:error, "mix.lock is not a map"}
  end
end
