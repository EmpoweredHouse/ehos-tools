# Credo for every package in packages/. Each package's `check` names this file with
# `--config-file`: without it Credo merges a `.credo.exs` from every directory above the one it
# runs in, which in a worktree under `.claude/worktrees/` is also the main checkout's.
%{
  configs: [
    %{
      name: "default",
      strict: true,
      files: %{
        included: ["lib/", "test/", "config/", "mix.exs"],
        excluded: [~r"/test/fixtures/"]
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
