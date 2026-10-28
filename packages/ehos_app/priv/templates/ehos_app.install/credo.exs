# Credo, as `mix precommit` and `ehosctl verify` run it: its default checks, and the opt-in ones
# that hold a rule of docs/elixir.md. Change it here; neither passes flags of its own.
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
