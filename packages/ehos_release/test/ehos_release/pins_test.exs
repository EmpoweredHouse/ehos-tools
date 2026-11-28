defmodule EhosRelease.PinsTest do
  use ExUnit.Case, async: true

  import Hammox

  alias EhosRelease.{GitMock, Pin, Pins, Source}

  setup :verify_on_exit!

  @sha String.duplicate("a", 40)
  @other String.duplicate("b", 40)

  @sources [
    %{kind: "mix_lock", path: "mix.lock"},
    %{kind: "workflows", path: ".github/workflows"},
    %{kind: "claude_settings", path: ".claude/settings.json"},
    %{kind: "json", path: "priv/pins.json"}
  ]

  @moduletag :tmp_dir

  test "reads the pins into the three repositories from each kind of file, and no other", %{
    tmp_dir: dir
  } do
    write(dir, "mix.lock", """
    %{
      "ehos_platform": {:git, "https://github.com/EmpoweredHouse/ehos-tools.git", "#{@sha}", [sparse: "packages/ehos_platform", ref: "#{@sha}"]},
      "heroicons": {:git, "https://github.com/tailwindlabs/heroicons.git", "#{@other}", [tag: "v2.2.0"]},
      "jason": {:hex, :jason, "1.4.4", "x", [:mix], [], "hexpm", "y"},
    }
    """)

    write(dir, ".github/workflows/release.yml", """
    jobs:
      open:
        uses: EmpoweredHouse/ehos-tools/.github/workflows/ehos-release.yml@#{@sha} # ehos_release-v0.1.0
      local:
        uses: ./.github/workflows/ci.yml
      build:
        runs-on: ubuntu-24.04
        steps:
          - uses: actions/checkout@#{@other}
          - run: echo hi
          - uses: docker://alpine:3
          - uses: EmpoweredHouse/eh-os@v1.2.3
    """)

    write(dir, ".github/workflows/README.md", "not a workflow")

    write(dir, ".claude/settings.json", """
    {"extraKnownMarketplaces": {
      "ehos-tools": {"source": {"source": "github", "repo": "EmpoweredHouse/ehos-tools", "ref": "ehos-dev-v0.14.0"}},
      "elsewhere": {"source": {"source": "github", "repo": "someone/else"}}
    }}
    """)

    write(dir, "priv/pins.json", """
    {"ehos_app": {"repository": "EmpoweredHouse/ehos-tools", "path": "packages/ehos_app", "ref": "#{@other}"}}
    """)

    assert Pins.read(Source.checkout(dir), @sources) ==
             {[
                pin(
                  "mix.lock",
                  "ehos_platform",
                  "EmpoweredHouse/ehos-tools",
                  "packages/ehos_platform",
                  @sha
                ),
                pin(
                  ".github/workflows/release.yml",
                  "build, step 4",
                  "EmpoweredHouse/eh-os",
                  "",
                  "v1.2.3"
                ),
                pin(
                  ".github/workflows/release.yml",
                  "open",
                  "EmpoweredHouse/ehos-tools",
                  ".github/workflows/ehos-release.yml",
                  @sha
                ),
                pin(
                  ".claude/settings.json",
                  "marketplace ehos-tools",
                  "EmpoweredHouse/ehos-tools",
                  ".claude-plugin/marketplace.json",
                  "ehos-dev-v0.14.0"
                ),
                pin(
                  "priv/pins.json",
                  "ehos_app",
                  "EmpoweredHouse/ehos-tools",
                  "packages/ehos_app",
                  @other
                )
              ], []}
  end

  test "refuses a missing file, a marketplace that follows a branch, and a ref that is neither a " <>
         "commit nor a tag",
       %{tmp_dir: dir} do
    write(dir, ".claude/settings.json", """
    {"extraKnownMarketplaces": {
      "ehos-tools": {"source": {"source": "github", "repo": "EmpoweredHouse/ehos-tools"}}
    }}
    """)

    write(dir, "priv/pins.json", """
    {"a": {"repository": "EmpoweredHouse/eh-os", "ref": "../../evil"}, "b": {"ref": "x"}}
    """)

    assert Pins.read(Source.checkout(dir), @sources) ==
             {[],
              [
                "mix.lock is missing",
                ".claude/settings.json: marketplace ehos-tools has no ref, so it follows a branch",
                ~s(priv/pins.json: a pins EmpoweredHouse/eh-os at "../../evil", ) <>
                  "which is neither a full commit nor a tag",
                "priv/pins.json: b needs a repository and a ref"
              ]}
  end

  test "reads a commit's files through git, where a missing file may be empty", %{tmp_dir: dir} do
    expect(GitMock, :show, fn ^dir, "base", "priv/pins.json" ->
      {:ok, ~s({"a": {"repository": "EmpoweredHouse/eh-os", "ref": "#{@sha}"}})}
    end)

    expect(GitMock, :show, fn ^dir, "base", "mix.lock" -> :missing end)

    assert Pins.read(
             Source.at(dir, "base", GitMock),
             [%{kind: "json", path: "priv/pins.json"}, %{kind: "mix_lock", path: "mix.lock"}],
             missing: :empty
           ) == {[pin("priv/pins.json", "a", "EmpoweredHouse/eh-os", "", @sha)], []}
  end

  test "names the pins a pull request adds or moves, and not those it keeps" do
    kept = pin("mix.lock", "a", "EmpoweredHouse/ehos-tools", "packages/ehos_app", @sha)
    moved = pin("mix.lock", "b", "EmpoweredHouse/ehos-tools", "packages/ehos_design", @sha)
    added = pin("mix.lock", "c", "EmpoweredHouse/eh-os", "", @sha)

    assert Pins.changed([kept, %{moved | ref: @other}], [kept, moved, added]) == [moved, added]
  end

  defp pin(file, name, repository, path, ref),
    do: %Pin{file: file, name: name, repository: repository, path: path, ref: ref}

  defp write(dir, path, contents) do
    path = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end
