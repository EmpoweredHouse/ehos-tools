defmodule Ehosctl.TargetsTest do
  use Ehosctl.Case, async: true

  # A binary is named `ehosctl_<target>`, and three files name it: `mix.exs` builds it,
  # CI tests and publishes it, and the Homebrew formula downloads it. A target renamed
  # in one of them and not the others breaks only where nobody is looking.
  @root Path.expand("../../../..", __DIR__)

  test "CI runs every target end to end, and no other" do
    ci = File.read!(Path.join(@root, ".github/workflows/ci.yml"))

    assert named(ci, ~r/target: (\w+) }/) == targets()
  end

  test "the Homebrew formula downloads every target, and no other" do
    formula = File.read!(Path.join(@root, "packaging/homebrew/ehosctl.rb"))

    assert named(formula, ~r/\/ehosctl_(\w+)"/) == targets()
  end

  defp targets do
    Mix.Project.config()[:releases][:ehosctl][:burrito][:targets]
    |> Keyword.keys()
    |> Enum.map(&Atom.to_string/1)
    |> Enum.sort()
  end

  # The targets `file` names where `pattern` captures one.
  defp named(file, pattern),
    do: pattern |> Regex.scan(file, capture: :all_but_first) |> List.flatten() |> Enum.sort()
end
