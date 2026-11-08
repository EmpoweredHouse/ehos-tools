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
end
