defmodule Ehosctl.FakeKeychain do
  @moduledoc """
  A keychain for tests, in place of the system's (`Ehosctl.TokenStore`): its items in a public
  ETS table, keyed by the whole `t:Ehosctl.TokenStore.key/0`, so tests that run beside each other
  in their own directories never meet.
  """

  @behaviour Ehosctl.TokenStore

  @table __MODULE__

  @doc "Creates the table, once, from `test_helper.exs`."
  @spec start() :: :ok
  def start do
    :ets.new(@table, [:public, :named_table, :set])
    :ok
  end

  @doc "Every item kept for the state directory `dir`, as `{name, url, secret}`."
  @spec items(Path.t()) :: [{String.t(), String.t(), String.t()}]
  def items(dir),
    do: for({{^dir, name, url}, secret} <- :ets.tab2list(@table), do: {name, url, secret})

  @impl Ehosctl.TokenStore
  def put(key, secret) do
    :ets.insert(@table, {{key.dir, key.name, key.url}, secret})
    :ok
  end

  @impl Ehosctl.TokenStore
  def get(key) do
    case :ets.lookup(@table, {key.dir, key.name, key.url}) do
      [{_key, secret}] -> {:ok, secret}
      [] -> :none
    end
  end

  @impl Ehosctl.TokenStore
  def delete(key) do
    :ets.delete(@table, {key.dir, key.name, key.url})
    :ok
  end
end

defmodule Ehosctl.LockedKeychain do
  @moduledoc "A keychain for tests that keeps nothing, as a locked or absent one."

  @behaviour Ehosctl.TokenStore

  @impl Ehosctl.TokenStore
  def put(_key, _secret), do: {:error, "the keychain is locked"}

  @impl Ehosctl.TokenStore
  def get(_key), do: {:error, "the keychain is locked"}

  @impl Ehosctl.TokenStore
  def delete(_key), do: :ok
end
