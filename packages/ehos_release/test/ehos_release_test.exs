defmodule EhosReleaseTest do
  use ExUnit.Case, async: true

  import Hammox

  alias EhosRelease.{GitHubMock, GitMock, Pin}

  setup :verify_on_exit!

  @moduletag :tmp_dir

  @kept String.duplicate("a", 40)
  @moved String.duplicate("b", 40)

  @config ~s({"components": {"shop": {"tag_prefix": "v", "changie_projects": ["shop"],
    "changelogs": ["CHANGELOG.md"], "version_files": [{"path": "mix.exs", "line": "  @version \\"{version}\\""}],
    "pins": [{"kind": "json", "path": "pins.json"}]}}})

  test "release/1 says what the package is, at a commit, producing and accepting nothing" do
    commit = String.duplicate("a", 40)

    assert EhosRelease.release(commit) == %{
             "schema" => "ehos.release/v1",
             "component" => "ehos_release",
             "version" => to_string(Application.spec(:ehos_release, :vsn)),
             "commit" => commit,
             "produces" => [],
             "accepts" => [],
             "requires" => %{}
           }
  end

  describe "pins/3" do
    test "checks only the pins the pull request adds or moves against its base", %{tmp_dir: dir} do
      write(dir, ".github/ehos-release.json", @config)
      write(dir, "pins.json", pins(%{"kept" => @kept, "moved" => @moved, "added" => @kept}))

      mock_base(dir, %{
        ".github/ehos-release.json" => @config,
        "pins.json" => pins(%{"kept" => @kept, "moved" => @kept})
      })

      expect(GitHubMock, :compare, 2, fn "EmpoweredHouse/eh-os", "main", _commit ->
        {:ok, "behind"}
      end)

      assert EhosRelease.pins(dir, "base", mocks()) ==
               {:ok, [pin("added", @kept), pin("moved", @moved)]}
    end

    test "checks every pin when the base cannot be read", %{tmp_dir: dir} do
      write(dir, ".github/ehos-release.json", @config)
      write(dir, "pins.json", pins(%{"kept" => @kept}))
      mock_base(dir, %{".github/ehos-release.json" => @config, "pins.json" => "not json"})
      expect(GitHubMock, :compare, fn "EmpoweredHouse/eh-os", "main", @kept -> {:ok, "ahead"} end)

      assert EhosRelease.pins(dir, "base", mocks()) ==
               {:error,
                [
                  "pins.json: kept pins EmpoweredHouse/eh-os at #{@kept}, " <>
                    "which is ahead of its main, not on it"
                ]}
    end

    test "checks the pins of a file the pull request drops from its configuration", %{
      tmp_dir: dir
    } do
      head_config = String.replace(@config, ~s({"kind": "json", "path": "pins.json"}), "")
      write(dir, ".github/ehos-release.json", head_config)
      write(dir, "pins.json", pins(%{"fork" => @moved}))

      mock_base(dir, %{
        ".github/ehos-release.json" => @config,
        "pins.json" => pins(%{"fork" => @kept})
      })

      expect(GitHubMock, :compare, fn "EmpoweredHouse/eh-os", "main", @moved ->
        {:ok, "diverged"}
      end)

      assert EhosRelease.pins(dir, "base", mocks()) ==
               {:error,
                [
                  "pins.json: fork pins EmpoweredHouse/eh-os at #{@moved}, " <>
                    "which is diverged of its main, not on it"
                ]}
    end

    test "refuses a repository with no configuration, and a base that could be read as an option",
         %{tmp_dir: dir} do
      assert EhosRelease.pins(dir, "base", mocks()) ==
               {:error, [".github/ehos-release.json is missing"]}

      assert EhosRelease.pins(dir, "--output=x", mocks()) ==
               {:error, [~s("--output=x" is not a commit or a branch)]}
    end
  end

  defp pin(name, ref),
    do: %Pin{
      file: "pins.json",
      name: name,
      repository: "EmpoweredHouse/eh-os",
      path: "",
      ref: ref
    }

  defp pins(refs) do
    JSON.encode!(
      Map.new(refs, fn {name, ref} ->
        {name, %{"repository" => "EmpoweredHouse/eh-os", "ref" => ref}}
      end)
    )
  end

  defp mock_base(dir, files) do
    stub(GitMock, :show, fn ^dir, "base", path ->
      case Map.fetch(files, path) do
        {:ok, contents} -> {:ok, contents}
        :error -> :missing
      end
    end)
  end

  defp mocks, do: [git: GitMock, github: GitHubMock]

  defp write(dir, path, contents) do
    path = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end
