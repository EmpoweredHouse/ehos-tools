# Credo, as `mix precommit` runs it, and `ehosctl verify` from 0.28.0: its default checks, and
# the opt-in ones that hold a rule of docs/elixir.md. Change it here; neither passes flags of
# its own.
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "config/", "priv/repo/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      checks: %{
        extra: [
          {Credo.Check.Refactor.AppendSingleItem, []}
        ]
      }
    }
  ]
}
