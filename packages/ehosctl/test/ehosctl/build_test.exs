defmodule Ehosctl.BuildTest do
  # The commit a build says it was made from (eh-os D-91), and that an incremental build that
  # is not forced takes a new one.
  use Ehosctl.Case, async: true

  test "a build says the commit it was made from, and recompiles when the checkout moves on" do
    # Not loaded until something calls it; `function_exported?/3` does not load it.
    assert function_exported?(Code.ensure_loaded!(Ehosctl), :__mix_recompile__?, 0)
    # Mix compiled this test run's code from the checkout as it is now.
    refute Ehosctl.__mix_recompile__?()
    assert Ehosctl.commit() == Ehosctl.Build.commit()
  end

  test "CI's GITHUB_SHA is the commit, and anything but a commit is none" do
    sha = String.duplicate("ab", 20)
    assert Ehosctl.Build.commit(%{"GITHUB_SHA" => sha}) == sha
    assert Ehosctl.Build.commit(%{"GITHUB_SHA" => "not a commit"}) == nil
  end
end
