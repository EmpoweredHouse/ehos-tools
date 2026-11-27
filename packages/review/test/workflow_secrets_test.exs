defmodule WorkflowSecretsTest do
  # The key of the GitHub App "ehos-tools CI" can make a token for each repository the App is
  # installed on, and a branch that changes a workflow can print any secret that workflow names.
  # ehos-tools and ehos_contract are public, so CI here needs no token, and no workflow names the
  # key (ehos-tools#1169; eh-os D-197 for the repositories that still need one). This holds against
  # a mistake, not against a workflow that reads every secret through `toJSON(secrets)`, nor a
  # branch that changes this test: what keeps the key from a branch is deleting the repository
  # secrets that held it.
  use ExUnit.Case, async: true

  @workflows Path.expand("../../../.github/workflows", __DIR__)
  @key ~r/EHOS_CI_APP_(?:ID|PRIVATE_KEY)/

  test "no workflow names the key of the CI GitHub App" do
    paths = Path.wildcard(Path.join(@workflows, "*.{yml,yaml}"))

    assert paths != []
    assert for(path <- paths, File.read!(path) =~ @key, do: Path.basename(path)) == []
  end
end
