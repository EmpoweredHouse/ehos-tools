defmodule EhosApp.CodexMigration do
  @moduledoc """
  Moves T-31's plugins to their current Codex marketplaces on upgrade: `ehos-app` to its own
  marketplace (T-32), and the contract's plugin from `eh-os-contract` to `ehos-contract`, the
  name the contract library took in `ehos_app` 0.38.0.
  """

  # What T-31's release wrote for each plugin, and the current pin's name that replaces it.
  @moves [
    %{
      pin: "ehos-app",
      marketplace: "ehos-tools",
      plugin: "ehos-app@ehos-tools",
      source: "https://github.com/EmpoweredHouse/ehos-tools.git",
      ref: "74229df5e5979eb3bbf02e5aeeba847050fbf7bc"
    },
    %{
      pin: "ehos-contract",
      marketplace: "eh-os-contract",
      plugin: "eh-os-contract@eh-os-contract",
      source: "https://github.com/EmpoweredHouse/eh-os-contract.git",
      ref: "f9242abf83d33bea76f2db52b28bbaba584769a8"
    }
  ]

  @doc """
  Migrates the installer-owned sources and plugins while retaining local settings and comments.
  Returns `:manual` if any entry conflicts or the exact change cannot be verified.
  """
  @spec migrate(String.t()) :: {:ok, String.t()} | :manual
  def migrate(content) do
    moves = Enum.map(@moves, &Map.put(&1, :to, pin(&1.pin)))

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
    markets[move.marketplace] == old_source(move) and Map.has_key?(plugins, move.plugin) and
      not Map.has_key?(markets, move.to.marketplace) and
      not Map.has_key?(plugins, new_plugin(move)) and
      not Enum.any?(
        Map.keys(Map.delete(plugins, move.plugin)),
        &String.ends_with?(&1, "@" <> move.marketplace)
      )
  end

  defp movable?(_move, _markets, _plugins), do: false

  defp expected(move, %{"marketplaces" => markets, "plugins" => plugins} = config) do
    %{
      config
      | "marketplaces" =>
          markets
          |> Map.delete(move.marketplace)
          |> Map.put(move.to.marketplace, new_source(move)),
        "plugins" =>
          plugins
          |> Map.delete(move.plugin)
          |> Map.put(new_plugin(move), plugins[move.plugin])
    }
  end

  defp revise(move, content) do
    content
    |> String.replace(
      ~r/^\[marketplaces\.#{Regex.escape(move.marketplace)}\]/m,
      "[marketplaces.#{move.to.marketplace}]"
    )
    |> String.replace(
      ~r/^\[plugins\."#{Regex.escape(move.plugin)}"\]/m,
      ~s([plugins."#{new_plugin(move)}"])
    )
    |> String.replace(
      ~r/^source = "#{Regex.escape(move.source)}"/m,
      ~s(source = "#{new_source(move)["source"]}")
    )
    |> String.replace(~r/^ref = "#{move.ref}"/m, ~s(ref = "#{move.to.commit}"))
  end

  defp old_source(move),
    do: %{"source_type" => "git", "source" => move.source, "ref" => move.ref}

  defp new_source(move) do
    %{
      "source_type" => "git",
      "source" => "https://github.com/#{move.to.repo}.git",
      "ref" => move.to.commit
    }
  end

  defp new_plugin(move), do: "#{move.to.name}@#{move.to.marketplace}"
end
