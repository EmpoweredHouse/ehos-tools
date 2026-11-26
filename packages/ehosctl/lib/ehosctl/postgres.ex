defmodule Ehosctl.Postgres do
  @moduledoc """
  How ehosctl writes a name for PostgreSQL to read: one rule, so the SQL that `resources
  prepare-sql` prints, and the `search_path` and JDBC `currentSchema` of a data session, quote a
  name the same way.
  """

  @doc """
  `name` as PostgreSQL's quoted identifier: in double quotes, with a double quote doubled.
  PostgreSQL then keeps its case, and SQL reads it as one name. The caller refuses what the
  quotes do not cover: a NUL byte, which PostgreSQL refuses in a name, and a space or a
  backslash where libpq's options read the name.

      iex> Ehosctl.Postgres.identifier("Ledger.Q1")
      ~s("Ledger.Q1")

      iex> Ehosctl.Postgres.identifier(~s(a"b))
      ~s("a""b")
  """
  @spec identifier(String.t()) :: String.t()
  def identifier(name), do: ~s(") <> String.replace(name, ~s("), ~s("")) <> ~s(")
end
