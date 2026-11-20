defmodule EhosPlatform.ExternalDatabasesTest do
  use ExUnit.Case, async: true

  alias EhosPlatform.ExternalDatabases

  doctest ExternalDatabases

  @ca File.read!("test/support/fixtures/certificates/ca-excluding-ip.pem")

  # An entry as the installer writes it, every field the chart names given.
  @entry %{
    "name" => "ledger",
    "version" => 17,
    "host" => "ledger.db.example.com",
    "port" => 5433,
    "database" => "ledger",
    "ca" => @ca,
    "addressRanges" => ["10.20.0.0/24"],
    "managingRoleSecret" => "ehos-external-ledger",
    "administratorRole" => "alice@example.com"
  }

  describe "read_back/1" do
    test "keeps each entry with the chart's fields alone, and says the keys it drops" do
      without_optional = Map.drop(@entry, ["port", "administratorRole"])

      assert ExternalDatabases.read_back([
               Map.merge(@entry, %{"extra" => "kept nowhere", "password" => "s3cret"}),
               Map.merge(without_optional, %{"port" => nil, "administratorRole" => nil})
             ]) ==
               {[@entry, without_optional],
                [
                  "The database outside the installation ledger has keys that the chart does " <>
                    "not name: extra, password. The install leaves them out."
                ]}

      assert {[@entry], [warning]} =
               ExternalDatabases.read_back([Map.put(@entry, "bad\e[2Jkey", 1)])

      assert warning =~ "(a name not shown)"
      refute warning =~ "\e"
    end

    # The chart's `ehos.wholeNumber` takes them as digits too.
    test "takes a port or a version given as digits, as the integer" do
      assert ExternalDatabases.read_back([%{@entry | "port" => "5433", "version" => "17"}]) ==
               {[@entry], []}
    end

    test "leaves out an entry with a field of another type, or without a field the chart needs" do
      for {broken, field} <- [
            {%{@entry | "version" => "seventeen"}, "version"},
            {%{@entry | "port" => "5433a"}, "port"},
            {%{@entry | "port" => "1234567"}, "port"},
            {%{@entry | "addressRanges" => "10.20.0.0/24"}, "addressRanges"},
            {%{@entry | "addressRanges" => ["10.20.0.0/24", 1]}, "addressRanges"},
            {%{@entry | "administratorRole" => 1}, "administratorRole"},
            {Map.delete(@entry, "ca"), "ca"}
          ] do
        assert ExternalDatabases.read_back([
                 broken,
                 %{@entry | "name" => "other", "managingRoleSecret" => "ehos-external-other"}
               ]) ==
                 {[%{@entry | "name" => "other", "managingRoleSecret" => "ehos-external-other"}],
                  [
                    "The database outside the installation ledger has no #{field} of the type " <>
                      "the chart takes. The install leaves it out of dataResources.external."
                  ]}
      end

      assert ExternalDatabases.read_back([Map.delete(@entry, "name"), "ledger"]) ==
               {nil,
                [
                  "An entry of dataResources.external has no name in the form the chart takes. " <>
                    "The install leaves it out of the list.",
                  "An entry of dataResources.external is not a map. The install leaves it out " <>
                    "of the list."
                ]}
    end

    test "leaves out, with a warning, an entry whose managing role is in another Secret" do
      assert ExternalDatabases.read_back([%{@entry | "managingRoleSecret" => "ledger-admin"}]) ==
               {nil,
                [
                  "The database outside the installation ledger keeps its managing role in the " <>
                    "Secret ledger-admin, and the installer keeps only ehos-external-ledger. The " <>
                    "install leaves the database out of dataResources.external. Add it again " <>
                    "to give it that Secret."
                ]}
    end

    test "leaves out an entry whose name is not in the chart's form, and never shows it" do
      for name <- ["led\e[2Jger", "Ledger", 1] do
        assert ExternalDatabases.read_back([%{@entry | "name" => name}]) ==
                 {nil,
                  [
                    "An entry of dataResources.external has no name in the form the chart " <>
                      "takes. The install leaves it out of the list."
                  ]}
      end

      assert {nil, [warning]} =
               ExternalDatabases.read_back([%{@entry | "managingRoleSecret" => "x\ny"}])

      refute warning =~ "\n"
      assert warning =~ "(a name not shown)"
    end

    test "is none for a list with no entry, or for no list" do
      for listed <- [[], nil, "ledger", %{"name" => "ledger"}],
          do: assert(ExternalDatabases.read_back(listed) == {nil, []})
    end
  end

  describe "check/1" do
    test "takes an entry the chart takes" do
      assert ExternalDatabases.check(@entry) == :ok
      assert ExternalDatabases.check(Map.drop(@entry, ["port", "administratorRole"])) == :ok
      assert ExternalDatabases.check(%{@entry | "addressRanges" => ["10.0.16.0/20"]}) == :ok
    end

    test "refuses each field as the chart would, naming the first" do
      for {field, value, rule} <- [
            {"name", "Ledger", "must be a DNS label of at most 50 characters"},
            {"name", String.duplicate("a", 51), "must be a DNS label"},
            {"name", "ehos-ledger", "must not start with ehos-"},
            {"version", 15, "16 or later"},
            {"version", "17", "16 or later"},
            {"host", "10.0.0.5", "not an address"},
            {"host", "ledger", "with a dot"},
            {"host", "Ledger.example.com", "lowercase"},
            {"port", 0, "from 1 to 65535"},
            {"port", 65_536, "from 1 to 65535"},
            {"database", "1ledger", "not starting with a digit"},
            {"database", "Ledger", "lowercase"},
            {"ca", "not a certificate", "one or more certificates in PEM"},
            {"ca", @ca <> "-----BEGIN PRIVATE KEY-----\n", "no private key"},
            {"addressRanges", [], "must list the IPv4 ranges"},
            {"addressRanges", ["10.0.0.0/16"], "/20 or narrower, and 10.0.0.0/16 is wider"},
            {"addressRanges", ["127.0.0.0/24"], "loopback"},
            {"addressRanges", ["169.254.169.0/24"], "169.254.0.0/16"},
            {"addressRanges", ["10.20.0.5/24"], "write 10.20.0.5/24 as 10.20.0.0/24"},
            {"addressRanges", ["10.20.0.0/24", "10.20.0.0/24"], "each range once"},
            {"addressRanges", ["2001:db8::/48"], "IPv4 ranges"},
            {"managingRoleSecret", "ehos-role-x", "ehos-role-"},
            {"managingRoleSecret", "removed-superuser", "-superuser, -app"},
            {"managingRoleSecret", "old-server", "CloudNativePG"},
            {"managingRoleSecret", "Upper", "the name of a Secret"},
            {"administratorRole", "ehos_admin", "must not start with ehos_ or pg_"},
            {"administratorRole", "PUBLIC", "nor be public"},
            {"administratorRole", "a b", "the name of a role"}
          ] do
        assert {:error, ^field, said} = ExternalDatabases.check(Map.put(@entry, field, value)),
               "#{field} #{inspect(value)}"

        assert said =~ rule
      end
    end
  end

  describe "secret/4" do
    test "is a basic-auth Secret in ehos-data, labelled and annotated as the installer's" do
      assert ExternalDatabases.secret("ledger", "ehos_manager", "s3cret") == %{
               "apiVersion" => "v1",
               "kind" => "Secret",
               "type" => "kubernetes.io/basic-auth",
               "metadata" => %{
                 "name" => "ehos-external-ledger",
                 "namespace" => "ehos-data",
                 "labels" => %{"app.kubernetes.io/managed-by" => "ehosctl"},
                 "annotations" => %{"ehos.empowered.house/external-database" => "ledger"}
               },
               "data" => %{
                 "username" => Base.encode64("ehos_manager"),
                 "password" => Base.encode64("s3cret")
               }
             }

      assert get_in(ExternalDatabases.secret("ledger", "u", "p", "42"), [
               "metadata",
               "resourceVersion"
             ]) == "42"
    end
  end

  describe "holder/2" do
    test "is ours only with the label, the annotation for the database, and no owner" do
      ours = ExternalDatabases.secret("ledger", "u", "p")
      assert ExternalDatabases.holder(ours, "ledger") == :ours

      for {held, why} <- [
            {put_in(ours, ["metadata", "ownerReferences"], [
               %{"kind" => "Cluster", "name" => "shared"}
             ]), "it belongs to the Cluster shared"},
            {put_in(ours, ["metadata", "labels"], %{}),
             "it does not have the label app.kubernetes.io/managed-by: ehosctl"},
            {put_in(ours, ["metadata", "annotations"], nil),
             "its annotation ehos.empowered.house/external-database does not name the " <>
               "database ledger"},
            {ExternalDatabases.secret("other", "u", "p"),
             "its annotation ehos.empowered.house/external-database does not name the " <>
               "database ledger"},
            {%{"kind" => "Secret"},
             "it does not have the label app.kubernetes.io/managed-by: ehosctl"}
          ] do
        assert ExternalDatabases.holder(held, "ledger") == {:theirs, why}
      end
    end
  end
end
