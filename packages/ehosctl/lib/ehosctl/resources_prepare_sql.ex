defmodule Ehosctl.ResourcesPrepareSql do
  @moduledoc """
  `ehosctl resources prepare-sql --database D --username R`: prints the SQL that prepares a
  PostgreSQL server outside the installation for EHOS (eh-os D-170, D-189): the managing role, its
  database, the right to grant `CONNECT` there, and `PUBLIC`'s rights taken away there and on
  every other database of the server.
  The administrator of the database runs it as their own role, then sets the role's password.

  It runs under `ehosctl resources` (`c:Ehosctl.Command.mounted/0`), on the local plane: it
  contacts nothing, changes nothing and names no password. Standard output is SQL alone, its
  explanation in `--` comments, so it can go to `psql` or a file as it is printed.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Output

  # PostgreSQL's NAMEDATALEN less its terminator: a longer name is cut, not refused.
  @max_name_bytes 63

  # The databases a provider keeps for itself on a server it manages, which its own role connects
  # to: Cloud SQL's, RDS's and Azure's. The statements leave their CONNECT as the provider set it.
  @providers_own ~w(cloudsqladmin rdsadmin azure_maintenance azure_sys)

  @impl Ehosctl.Command
  def name, do: :"prepare-sql"

  @impl Ehosctl.Command
  def plane, do: :local

  @impl Ehosctl.Command
  def group, do: :installation

  @impl Ehosctl.Command
  def summary, do: "Print the SQL that prepares a database outside the installation."

  @impl Ehosctl.Command
  def spec,
    do: [
      about:
        "Print the SQL that prepares a PostgreSQL server outside the installation, such as one " <>
          "on Cloud SQL or RDS, for EHOS. The SQL makes the managing role and its database, " <>
          "and lets the managing role give the roles that EHOS makes the right to connect " <>
          "there. It takes from PUBLIC the right to create in that database and to connect to " <>
          "any database. Run it as your own role in psql. ehosctl contacts nothing, and the " <>
          "SQL names no password.",
      options: [
        database: [
          long: "--database",
          value_name: "DATABASE",
          required: true,
          help: "The database that the SQL makes for EHOS, such as apps."
        ],
        username: [
          long: "--username",
          value_name: "ROLE",
          required: true,
          help: "The managing role that the SQL makes, such as ehos_manager."
        ]
      ]
    ]

  @doc """
  Prints the statements for `--database` and `--username`, or refuses a name PostgreSQL would
  not keep as it is given, before anything is printed.
  """
  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], parsed, _opts) do
    %{database: database, username: username} = parsed.options

    with :ok <- named("--database", database),
         :ok <- in_block(database),
         :ok <- named("--username", username) do
      # It has no --json: the SQL is its only output, printed as it is.
      IO.puts(sql(database, username))
      0
    end
  end

  @doc """
  The statements that prepare `database` for the managing role `username`, with comments that
  say how to run them. Each name is quoted as an identifier, and `database` also as a literal.
  The first line makes psql stop at the first statement that fails, so a role or a database that
  exists already gets no grant or revoke meant for a new one, when psql reads them from a file or a
  pipe. Pasted into psql at its prompt, the lines after a failed one still run, so the comments
  say not to.

      iex> Ehosctl.ResourcesPrepareSql.sql("apps", "ehos_manager") =~
      ...>   ~s(CREATE ROLE "ehos_manager" WITH LOGIN CREATEROLE NOCREATEDB CONNECTION LIMIT 10;)
      true
  """
  @spec sql(String.t(), String.t()) :: String.t()
  def sql(database, username) do
    db = identifier(database)
    role = identifier(username)
    providers_own = Enum.map_join(@providers_own, ", ", &literal/1)

    """
    \\set ON_ERROR_STOP on
    -- Save these lines to a file, and run it with psql -f as your own role on the server of
    -- the database. Do not paste them: psql at its prompt runs the lines after a failed one.
    -- They name no password. Then set the password of the managing role in psql:
    --   \\password #{role}
    CREATE ROLE #{role} WITH LOGIN CREATEROLE NOCREATEDB CONNECTION LIMIT 10;
    CREATE DATABASE #{db};
    GRANT CREATE ON DATABASE #{db} TO #{role};
    -- EHOS gives each role that it makes the right to connect, so PUBLIC needs none.
    GRANT CONNECT ON DATABASE #{db} TO #{role} WITH GRANT OPTION;
    GRANT CONNECT ON DATABASE #{db} TO CURRENT_USER;
    REVOKE CONNECT, CREATE, TEMPORARY ON DATABASE #{db} FROM PUBLIC;
    -- The DO block takes CONNECT from PUBLIC only on the databases that your role may change.
    -- For a database that your role does not own, psql shows a warning. Ask its owner to run:
    --   REVOKE CONNECT ON DATABASE <the database> FROM PUBLIC;
    DO $$
    DECLARE
      other text;
    BEGIN
      FOR other IN
        SELECT datname FROM pg_catalog.pg_database
        WHERE datallowconn AND datname <> #{literal(database)}
          AND datname NOT IN (#{providers_own})
          AND has_database_privilege('public', oid, 'CONNECT')
      LOOP
        EXECUTE format('REVOKE CONNECT ON DATABASE %I FROM PUBLIC', other);
      END LOOP;
    END
    $$;\
    """
  end

  defp named(option, name) do
    cond do
      name == "" ->
        {:error, :invalid, "#{option} is empty. Give a name. ehosctl printed nothing."}

      byte_size(name) > @max_name_bytes ->
        {:error, :invalid,
         "#{option} is #{byte_size(name)} bytes long. PostgreSQL keeps #{@max_name_bytes} bytes " <>
           "of a name or fewer. Give a shorter name. ehosctl printed nothing."}

      # A format character, such as a bidirectional override or a zero-width space, would make
      # the printed name read as another one.
      not Output.printable?(name) ->
        {:error, :invalid,
         "#{option} holds a control or format character, or a byte that is not UTF-8. Give a " <>
           "name without one. ehosctl printed nothing."}

      # A literal reads `\'` as an escaped quote where standard_conforming_strings is off, and
      # psql reads a backslash in its `\password` line.
      String.contains?(name, "\\") ->
        {:error, :invalid,
         "#{option} holds a backslash, which PostgreSQL can read as an escape. Give a name " <>
           "without one. ehosctl printed nothing."}

      true ->
        :ok
    end
  end

  # The database's name is a literal inside the DO block's dollar-quoted body, which PostgreSQL
  # ends at the first `$$` it finds, inside a literal or not.
  defp in_block(database) do
    if String.contains?(database, "$$"),
      do:
        {:error, :invalid,
         "--database holds $$, which ends the DO block of the SQL. Give a name without it. " <>
           "ehosctl printed nothing."},
      else: :ok
  end

  defp identifier(name), do: ~s(") <> String.replace(name, ~s("), ~s("")) <> ~s(")
  defp literal(name), do: "'" <> String.replace(name, "'", "''") <> "'"
end
