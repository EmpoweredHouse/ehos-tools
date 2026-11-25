defmodule EhosApp.CodexMigrationTest do
  use ExUnit.Case, async: true

  alias EhosApp.CodexMigration

  test "leaves conflicting, shared, malformed and developer-owned sources for manual reconciliation" do
    old = File.read!("test/fixtures/codex-t31.toml")

    for custom <- [
          old <> "\n[marketplaces.ehos-app]\nsource_type = \"local\"\n",
          old <> "\n[plugins.\"ehos-dev@ehos-tools\"]\nenabled = true\n",
          old <> "\n[invalid",
          String.replace(old, "EmpoweredHouse/ehos-tools.git", "other/ehos-tools.git"),
          String.replace(old, "74229df5", "12345678"),
          old <> "\n[marketplaces.ehos-contract]\nsource_type = \"local\"\n",
          String.replace(old, "f9242abf", "12345678")
        ] do
      assert :manual = CodexMigration.migrate(custom)
    end
  end
end
