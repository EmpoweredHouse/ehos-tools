defmodule ProcedureTest do
  # The pre-pr-review skills of the two plugins follow one procedure and one correctness review,
  # and each plugin is installed alone, so each carries a copy of both
  # (plugins/*/skills/pre-pr-review/references/). This package holds the review gate, and keeps the
  # copies one.
  use ExUnit.Case, async: true

  for file <- ["procedure.md", "correctness.md"] do
    @file_name file
    @copies Enum.map(
              ["ehos-dev", "ehos-app"],
              &Path.expand(
                "../../../plugins/#{&1}/skills/pre-pr-review/references/#{file}",
                __DIR__
              )
            )

    test "both plugins' pre-pr-review skills carry the same #{file}" do
      [ehos_dev, ehos_app] = Enum.map(@copies, &File.read!/1)

      assert ehos_app == ehos_dev,
             "edit one copy of #{@file_name} and copy it over the other: #{Enum.join(@copies, ", ")}"
    end
  end

  # `code-review`, `/security-review`, `engineering:code-review`, in any form, but not a word that
  # ends in "-review" otherwise, such as `pre-pr-review`.
  @harness_reviewer ~r/(?<![\w-])(?:engineering:)?(?:code|security)-review(?![\w-])/

  # T-23: the reviews read the change themselves, and invoke no reviewer of the harness's, which
  # reads the session's own directory.
  test "no skill of the two plugins names a reviewer of the harness's" do
    plugins = Path.expand("../../../plugins", __DIR__)
    paths = Path.wildcard(Path.join(plugins, "**/*.md"))

    named =
      for path <- paths,
          name <- Regex.scan(@harness_reviewer, File.read!(path)),
          do: {Path.relative_to(path, plugins), hd(name)}

    assert paths != []
    assert named == []
  end
end
