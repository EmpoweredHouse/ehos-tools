defmodule Ehosctl.Postgres do
  @moduledoc """
  How ehosctl writes a name for PostgreSQL to read: one rule, so the SQL that `resources
  prepare-sql` prints and the `search_path` of a data session quote a name the same way.
  """

  @doc """
  `name` as PostgreSQL's quoted identifier: in double quotes, with a double quote doubled.
  PostgreSQL then keeps its case and reads it as one name, whatever it holds.

      iex> Ehosctl.Postgres.identifier("Ledger.Q1")
      ~s("Ledger.Q1")

      iex> Ehosctl.Postgres.identifier(~s(a"b))
      ~s("a""b")
  """
  @spec identifier(String.t()) :: String.t()
  def identifier(name), do: ~s(") <> String.replace(name, ~s("), ~s("")) <> ~s(")
end
