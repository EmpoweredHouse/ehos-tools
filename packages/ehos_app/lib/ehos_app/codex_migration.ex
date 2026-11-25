defmodule EhosApp.CodexMigration do
  @moduledoc """
  Moves T-31's plugins to their current Codex marketplaces on upgrade: `ehos-app` to its own
  marketplace (T-32), and the contract's plugin from `eh-os-contract` to `ehos-contract`, the
  name the contract library took in `ehos_app` 0.38.0.
  """

  # Each move: `from:`, what T-31's release wrote for a plugin, which the upgrade looks for word for
  # word and replaces; `to:`, the name of the current pin in `EhosApp.PluginPins` that it becomes.
  # The old names stay here because they are what an existing `.codex/config.toml` has. `migrate/1`
  # puts that pin itself under `pin:`.
  @moves [
    %{
      from: %{
        marketplace: "ehos-tools",
        plugin: "ehos-app@ehos-tools",
        source: "https://github.com/EmpoweredHouse/ehos-tools.git",
        ref: "74229df5e5979eb3bbf02e5aeeba847050fbf7bc"
      },
      to: "ehos-app"
    },
    %{
      from: %{
        marketplace: "eh-os-contract",
        plugin: "eh-os-contract@eh-os-contract",
        source: "https://github.com/EmpoweredHouse/eh-os-contract.git",
        ref: "f9242abf83d33bea76f2db52b28bbaba584769a8"
      },
      to: "ehos-contract"
    }
  ]

  @doc """
  Migrates the installer-owned sources and plugins while retaining local settings and comments.
  Returns `:manual` if any entry conflicts or the exact change cannot be verified.
  """
  @spec migrate(String.t()) :: {:ok, String.t()} | :manual
  def migrate(content) do
    moves = Enum.map(@moves, &Map.put(&1, :pin, pin(&1.to)))

    with {:ok, %{"marketplaces" => markets, "plugins" => plugins} = config} <-
           Toml.decode(content),
         true <- Enum.all?(moves, &movable?(&1, markets, plugins)) do
      expected = Enum.reduce(moves, config, &expected/2)
      revised = Enum.reduce(moves, content, &revise/2)

      if Toml.decode(revised) == {:ok, expected}, do: {:ok, revised}, else: :manual
    else
      _other -> :manual
    end
  end

  defp pin(name), do: Enum.find(EhosApp.PluginPins.all(), &(&1.name == name))

  # The old entries are exactly what T-31 wrote, the new names are free, and no other plugin
  # shares the old marketplace.
  defp movable?(move, markets, plugins) when is_map(markets) and is_map(plugins) do
    markets[move.from.marketplace] == old_source(move) and Map.has_key?(plugins, move.from.plugin) and
      not Map.has_key?(markets, move.pin.marketplace) and
      not Map.has_key?(plugins, new_plugin(move)) and
      not Enum.any?(
        Map.keys(Map.delete(plugins, move.from.plugin)),
        &String.ends_with?(&1, "@" <> move.from.marketplace)
      )
  end

  defp movable?(_move, _markets, _plugins), do: false

  defp expected(move, %{"marketplaces" => markets, "plugins" => plugins} = config) do
    %{
      config
      | "marketplaces" =>
          markets
          |> Map.delete(move.from.marketplace)
          |> Map.put(move.pin.marketplace, new_source(move)),
        "plugins" =>
          plugins
          |> Map.delete(move.from.plugin)
          |> Map.put(new_plugin(move), plugins[move.from.plugin])
    }
  end

  defp revise(move, content) do
    content
    |> String.replace(
      ~r/^\[marketplaces\.#{Regex.escape(move.from.marketplace)}\]/m,
      "[marketplaces.#{move.pin.marketplace}]"
    )
    |> String.replace(
      ~r/^\[plugins\."#{Regex.escape(move.from.plugin)}"\]/m,
      ~s([plugins."#{new_plugin(move)}"])
    )
    |> String.replace(
      ~r/^source = "#{Regex.escape(move.from.source)}"/m,
      ~s(source = "#{new_source(move)["source"]}")
    )
    |> String.replace(~r/^ref = "#{move.from.ref}"/m, ~s(ref = "#{move.pin.commit}"))
  end

  defp old_source(%{from: from}),
    do: %{"source_type" => "git", "source" => from.source, "ref" => from.ref}

  defp new_source(move) do
    %{
      "source_type" => "git",
      "source" => "https://github.com/#{move.pin.repo}.git",
      "ref" => move.pin.commit
    }
  end

  defp new_plugin(move), do: "#{move.pin.name}@#{move.pin.marketplace}"
end
