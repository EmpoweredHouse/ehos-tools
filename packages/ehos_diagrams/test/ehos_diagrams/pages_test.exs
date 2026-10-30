defmodule EhosDiagrams.PagesTest do
  # Moved from eh-os's Ehos.Dev.DiagramsTest with the code (T-21).
  use ExUnit.Case, async: true

  alias EhosDiagrams.Pages

  @moduletag :tmp_dir

  test "say which image is missing, and which output is unlinked", %{
    tmp_dir: dir
  } do
    out = Path.join(dir, "img")
    File.mkdir_p!(out)
    File.write!(Path.join(out, "linked.svg"), "")
    File.write!(Path.join(out, "unlinked.svg"), "")

    page = Path.join(dir, "page.txt")

    File.write!(page, """
    ![a](img/linked.svg "A title")
    ![b](img/missing.svg)
    ![c](img/themed.svg#gh-dark-mode-only)
    <img src="img/html.svg" alt="d">
    ![e](https://example.com/remote.svg)
    """)

    File.write!(Path.join(out, "themed.svg"), "")
    File.write!(Path.join(out, "html.svg"), "")

    problems = Pages.problems([page], out)

    assert Enum.any?(problems, &(&1 =~ "missing.svg, which does not exist"))
    assert Enum.any?(problems, &(&1 =~ "unlinked.svg is linked from no page"))

    refute Enum.any?(problems, &(&1 =~ ~r{/(linked|themed|html)\.svg is linked from no page}))
    refute Enum.any?(problems, &(&1 =~ "remote.svg"))
  end

  test "refuse a Mermaid block in any document, however fenced or indented, and nothing else",
       %{
         tmp_dir: dir
       } do
    plan = Path.join(dir, "docs/plans/a-plan.md")
    legacy = Path.join(dir, "docs/architecture/ARCHITECTURE-legacy.md")
    tilde = Path.join(dir, "docs/TESTING.md")
    prose = Path.join(dir, "docs/INSTALLING.md")
    long = Path.join(dir, "docs/releases.md")
    listed = Path.join(dir, "docs/ROADMAP.md")
    bare = Path.join(dir, "docs/VISION.md")
    quoted = Path.join(dir, "docs/DESIGN.md")
    marker = Path.join(dir, "docs/BUILDING.md")
    named = Path.join(dir, "docs/DEVELOPMENT.md")

    for {page, text} <- [
          {plan, "```mermaid\nflowchart LR\n```\n"},
          {legacy, "  ``` mermaid\nflowchart LR\n  ```\n"},
          {tilde, "~~~mermaid\nflowchart LR\n~~~\n"},
          {prose, "We used to draw with mermaid; ```elixir\nIO.puts(1)\n```\n"},
          {long, "````mermaid\nflowchart LR\n````\n"},
          {listed, "- A step:\n\n  ```mermaid\n  flowchart LR\n  ```\n"},
          {bare, "```\nmermaid is a word here\n```\n"},
          {quoted, "> ```Mermaid\n> flowchart LR\n> ```\n"},
          {marker, "1. ```mermaid\n   flowchart LR\n   ```\n"},
          {named, "```mermaid-js\nnot rendered as a diagram\n```\n"}
        ] do
      File.mkdir_p!(Path.dirname(page))
      File.write!(page, text)
    end

    documents = [plan, legacy, tilde, prose, long, listed, bare, quoted, marker, named]

    assert Pages.mermaid(documents) == [
             "#{plan} holds a Mermaid block (eh-os D-107)",
             "#{legacy} holds a Mermaid block (eh-os D-107)",
             "#{tilde} holds a Mermaid block (eh-os D-107)",
             "#{long} holds a Mermaid block (eh-os D-107)",
             "#{listed} holds a Mermaid block (eh-os D-107)",
             "#{quoted} holds a Mermaid block (eh-os D-107)",
             "#{marker} holds a Mermaid block (eh-os D-107)"
           ]
  end

  test "read a reference's definition, and a link from the repository's root", %{tmp_dir: dir} do
    out = Path.join(dir, "img")
    File.mkdir_p!(out)
    File.write!(Path.join(out, "referenced.svg"), "")
    File.write!(Path.join(out, "rooted.svg"), "")
    page = Path.join(dir, "docs/page.md")
    File.mkdir_p!(Path.dirname(page))

    File.write!(page, """
    ![a [fig] \\] 1][diagram] ![Collapsed][] ![shortcut] ![x][Wrapped
    Label] ![inline](../img/inline.svg)

    [diagram]: ../img/referenced.svg
    [collapsed]: ../img/collapsed.svg
    [SHORTCUT]: ../img/shortcut.svg
    [wrapped  label]: ../img/wrapped.svg
    [unused]: ../img/unused.svg
    See [the text][text].

    [text]: ../img/text.svg
    """)

    for name <- ~w(unused collapsed shortcut wrapped inline),
        do: File.write!(Path.join(out, name <> ".svg"), "")

    File.write!(Path.join(out, "text.svg"), "")

    # A link from the root is read from the current directory, which is the repository's root
    # when a host runs the check.
    rooted = Path.join(dir, "docs/rooted.md")
    File.write!(rooted, "![b](/#{Path.relative_to_cwd(Path.join(out, "rooted.svg"))})\n")

    assert Pages.problems([page, rooted], out) == [
             "#{out}/text.svg is linked from no page",
             "#{out}/unused.svg is linked from no page"
           ]
  end
end
