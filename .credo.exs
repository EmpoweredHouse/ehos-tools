# Credo for every package in packages/, which reads this file from the repository's root: Credo
# merges a `.credo.exs` from each directory above the one it runs in. A package's own file, beside
# its `mix.exs`, would win over this one; none has one.
%{
  configs: [
    %{
      name: "default",
      strict: true,
      files: %{
        included: ["lib/", "test/", "mix.exs"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/priv/templates/", ~r"/test/fixtures/"]
      },
      checks: %{
        disabled: [
          # The installer names Igniter's modules in full (`Igniter.Project.Deps`), which reads
          # better at each call than an alias defined far above it.
          {Credo.Check.Design.AliasUsage, []}
        ]
        # Not `Refactor.AppendSingleItem`: CONTRIBUTING.md's rule is `acc ++ [item]` in a loop,
        # and the check flags every `++ [item]`, a one-off included, so a review reads for it.
      }
    }
  ]
}
