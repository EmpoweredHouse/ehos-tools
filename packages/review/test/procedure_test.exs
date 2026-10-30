defmodule ProcedureTest do
  # The pre-pr-review skills of the two plugins follow one procedure, and each plugin is installed
  # alone, so each carries a copy of it (plugins/*/skills/pre-pr-review/references/procedure.md).
  # This package holds the review gate, and keeps the copies one.
  use ExUnit.Case, async: true

  @copies Enum.map(
            ["ehos-dev", "ehos-app"],
            &Path.expand(
              "../../../plugins/#{&1}/skills/pre-pr-review/references/procedure.md",
              __DIR__
            )
          )

  test "both plugins' pre-pr-review skills follow the same procedure" do
    [ehos_dev, ehos_app] = Enum.map(@copies, &File.read!/1)

    assert ehos_app == ehos_dev,
           "edit one copy of the procedure and copy it over the other: #{Enum.join(@copies, ", ")}"
  end
end
