defmodule Ehosctl.TargetsTest do
  use Ehosctl.Case, async: true

  # A binary is named `ehosctl_<target>`, and three files name it: `mix.exs` builds it,
  # CI tests and publishes it, and the Homebrew formula downloads it. A target renamed
  # in one of them and not the others breaks only where nobody is looking.
  @root Path.expand("../../../..", __DIR__)

  defp targets do
    Mix.Project.config()[:releases][:ehosctl][:burrito][:targets] |> Keyword.keys()
  end

  test "CI runs every target end to end" do
    ci = File.read!(Path.join(@root, ".github/workflows/ci.yml"))

    for target <- targets() do
      assert ci =~ "target: #{target} }", "no e2e job for #{target} in ci.yml"
    end
  end

  test "the Homebrew formula downloads every target" do
    formula = File.read!(Path.join(@root, "packaging/homebrew/ehosctl.rb"))

    for target <- targets() do
      assert formula =~ ~s(/ehosctl_#{target}"), "no url for #{target} in the formula"
    end
  end
end
