defmodule Ehosctl.ResourcesPrepareSqlTest do
  # `ehosctl resources prepare-sql` (eh-os D-170, ehos-tools#1006): the SQL that prepares a
  # database outside the installation. Not async: capture_io(:stderr) captures stderr for every
  # process.
  use Ehosctl.Case, async: false

  doctest Ehosctl.ResourcesPrepareSql

  @moduletag :tmp_dir

  # The statements eh-os's walk-through ran as a non-superuser administrator on PostgreSQL 16,
  # after which EHOS's check passed, after a line that makes psql stop at the first that fails.
  @sql """
  \\set ON_ERROR_STOP on
  -- Run these statements in psql, as your own role on the server of the database.
  -- They name no password. Then set the password of the managing role in psql:
  --   \\password "ehos_manager"
  CREATE ROLE "ehos_manager" WITH LOGIN CREATEROLE NOCREATEDB CONNECTION LIMIT 10;
  CREATE DATABASE "apps";
  GRANT CREATE ON DATABASE "apps" TO "ehos_manager";
  REVOKE CREATE, TEMPORARY ON DATABASE "apps" FROM PUBLIC;
  DO $$
  DECLARE
    other text;
  BEGIN
    FOR other IN
      SELECT datname FROM pg_catalog.pg_database
      WHERE datallowconn AND datname <> 'apps'
        AND datname NOT IN ('cloudsqladmin', 'rdsadmin', 'azure_maintenance', 'azure_sys')
        AND has_database_privilege('public', oid, 'CONNECT')
    LOOP
      EXECUTE format('REVOKE CONNECT ON DATABASE %I FROM PUBLIC', other);
    END LOOP;
  END
  $$;
  """

  setup %{tmp_dir: dir} do
    # No installation is known and nobody is signed in: the command needs neither.
    %{opts: [config_dir: dir]}
  end

  test "prints the statements that prepare the database, on stdout alone", %{opts: opts} do
    assert ehosctl(~w(resources prepare-sql --database apps --username ehos_manager), opts) ==
             {0, @sql, ""}
  end

  test "quotes each name as an identifier, and the database also as a literal", %{opts: opts} do
    {0, sql, ""} =
      ehosctl(
        ["resources", "prepare-sql", "--database", ~s(it's "apps"), "--username", ~s(a"b)],
        opts
      )

    assert sql =~ ~s(--   \\password "a""b"\n)
    assert sql =~ ~s(CREATE ROLE "a""b" WITH LOGIN)
    assert sql =~ ~s(CREATE DATABASE "it's ""apps""";\n)
    assert sql =~ ~s(GRANT CREATE ON DATABASE "it's ""apps""" TO "a""b";\n)
    assert sql =~ ~s(WHERE datallowconn AND datname <> 'it''s "apps"'\n)
  end

  test "refuses a name PostgreSQL would not keep as given, and prints nothing", %{opts: opts} do
    long = String.duplicate("a", 64)

    for {args, refused} <- [
          {["--database", "", "--username", "r"],
           "--database is empty. Give a name. ehosctl printed nothing."},
          {["--database", "apps", "--username", long],
           "--username is 64 bytes long. PostgreSQL keeps 63 bytes of a name or fewer. Give a " <>
             "shorter name. ehosctl printed nothing."},
          {["--database", "a\nb", "--username", "r"],
           "--database holds a control or format character, or a byte that is not UTF-8. Give " <>
             "a name without one. ehosctl printed nothing."},
          {["--database", "apps", "--username", "r\e[2J"],
           "--username holds a control or format character, or a byte that is not UTF-8. Give " <>
             "a name without one. ehosctl printed nothing."},
          # A right-to-left override and a zero-width space, which make a name read as another.
          {["--database", "apps\u202E", "--username", "r"],
           "--database holds a control or format character, or a byte that is not UTF-8. Give " <>
             "a name without one. ehosctl printed nothing."},
          {["--database", "apps", "--username", "ehos\u200Bmanager"],
           "--username holds a control or format character, or a byte that is not UTF-8. Give " <>
             "a name without one. ehosctl printed nothing."},
          {["--database", "x\\", "--username", "r"],
           "--database holds a backslash, which PostgreSQL can read as an escape. Give a name " <>
             "without one. ehosctl printed nothing."},
          {["--database", "apps", "--username", "a\\b"],
           "--username holds a backslash, which PostgreSQL can read as an escape. Give a name " <>
             "without one. ehosctl printed nothing."},
          {["--database", "a$$b", "--username", "r"],
           "--database holds $$, which ends the DO block of the SQL. Give a name without it. " <>
             "ehosctl printed nothing."}
        ] do
      assert ehosctl(["resources", "prepare-sql" | args], opts) ==
               {2, "", "ehosctl: #{refused}\n"}
    end

    # 63 bytes of a name in two-byte characters is a name PostgreSQL keeps.
    assert {0, _sql, ""} =
             ehosctl(
               ~w(resources prepare-sql --database apps --username) ++
                 [String.duplicate("é", 31) <> "a"],
               opts
             )
  end

  test "needs both names", %{opts: opts} do
    assert {2, "", stderr} = ehosctl(~w(resources prepare-sql --database apps), opts)
    assert stderr =~ "--username"
  end

  test "names its own plane in its help, and takes no --installation" do
    {0, help, ""} = ehosctl(~w(help resources prepare-sql), [])
    assert help =~ "Plane: local."
    refute help =~ "--installation"
  end
end
