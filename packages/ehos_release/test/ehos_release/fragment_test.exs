defmodule EhosRelease.FragmentTest do
  use ExUnit.Case, async: true

  import EhosRelease.ReleaseRepo

  alias EhosRelease.{ChangieConfig, Fragment, Source}

  @moduletag :tmp_dir

  @config %ChangieConfig{changes_dir: ".changes", unreleased_dir: "unreleased", projects: %{}}

  test "reads the fragments of the projects asked for, and leaves the others out", %{tmp_dir: dir} do
    fragment!(dir, "a.yaml")
    fragment!(dir, "b.yaml", "Fixed", "shop_ui")

    assert Fragment.read(Source.checkout(dir), @config, ["shop"]) ==
             {[
                %Fragment{
                  file: ".changes/unreleased/a.yaml",
                  project: "shop",
                  kind: "Added",
                  body: "A thing",
                  breaking: false,
                  issue: "EmpoweredHouse/eh-os#7"
                }
              ], []}
  end

  test "refuses a kind outside Keep a Changelog's, an issue of another repository, a Breaking " <>
         "that is not Yes or No, and a file that is no fragment, whatever its project",
       %{tmp_dir: dir} do
    write(dir, ".changes/unreleased/a.yaml", fragment("Improved", "No", "EmpoweredHouse/eh-os#1"))
    write(dir, ".changes/unreleased/b.yaml", fragment("Added", "No", "someone/else#1"))
    write(dir, ".changes/unreleased/c.yaml", fragment("Added", "Maybe", "EmpoweredHouse/eh-os#1"))
    write(dir, ".changes/unreleased/d.yaml", "- a list\n")

    assert Fragment.read(Source.checkout(dir), @config, ["other"]) ==
             {[],
              [
                ~s(.changes/unreleased/a.yaml: "Improved" is not one of Added, Changed, ) <>
                  "Deprecated, Removed, Fixed, Security",
                ".changes/unreleased/b.yaml: Issue is not an issue of eh-os, ehos-tools or " <>
                  "ehos_contract, owner/repo#n",
                ".changes/unreleased/c.yaml: Breaking is not Yes or No",
                ".changes/unreleased/d.yaml is not a fragment changie can read"
              ]}
  end

  defp fragment(kind, breaking, issue) do
    """
    project: shop
    kind: #{kind}
    body: x
    custom:
        Breaking: "#{breaking}"
        Issue: #{issue}
    """
  end
end
