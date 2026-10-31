# Credo for the packages in packages/ that run it (CONTRIBUTING.md, "The gate"). Each names this
# file in a `credo` alias with `--config-file`: without it Credo merges a `.credo.exs` from every
# directory above the one it runs in, which in a worktree under `.claude/worktrees/` is also the
# main checkout's.
%{
  configs: [
    %{
      name: "default",
      strict: true,
      files: %{
        # `../../test/support/`: the repository's test support, which a package compiles in
        # `test` from where it is (ehos-tools#690).
        included: ["lib/", "test/", "config/", "mix.exs", "../../test/support/"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      },
      checks: %{
        disabled: [
          # A module named in full at each call (`Igniter.Project.Deps` in ehos_app's installer)
          # reads better than an alias defined far above it.
          {Credo.Check.Design.AliasUsage, []}
        ]
        # Not `Refactor.AppendSingleItem`: CONTRIBUTING.md's rule is `acc ++ [item]` in a loop,
        # and the check flags every `++ [item]`, a one-off included, so a review reads for it.
      }
    }
  ]
}
