defmodule EhosApp.CodexMigration do
  @moduledoc "Moves T-31's application plugin to its own Codex marketplace on upgrade."

  @old_ref "74229df5e5979eb3bbf02e5aeeba847050fbf7bc"
  @old_plugin "ehos-app@ehos-tools"
  @new_plugin "ehos-app@ehos-app"
  @old_source %{
    "source_type" => "git",
    "source" => "https://github.com/EmpoweredHouse/ehos-tools.git",
    "ref" => @old_ref
  }

  @doc """
  Migrates the installer-owned source and plugin while retaining local settings and comments.
  Returns `:manual` if either entry conflicts or the exact change cannot be verified.
  """
  @spec migrate(String.t()) :: {:ok, String.t()} | :manual
  def migrate(content) do
    with {:ok,
          %{
            "marketplaces" => %{"ehos-tools" => @old_source} = markets,
            "plugins" => %{@old_plugin => plugin} = plugins
          } = config} <- Toml.decode(content),
         false <- Map.has_key?(markets, "ehos-app") or Map.has_key?(plugins, @new_plugin),
         false <-
           Enum.any?(
             Map.keys(Map.delete(plugins, @old_plugin)),
             &String.ends_with?(&1, "@ehos-tools")
           ) do
      pin = Enum.find(EhosApp.PluginPins.all(), &(&1.name == "ehos-app"))

      expected = %{
        config
        | "marketplaces" =>
            markets
            |> Map.delete("ehos-tools")
            |> Map.put("ehos-app", %{@old_source | "ref" => pin.commit}),
          "plugins" => plugins |> Map.delete(@old_plugin) |> Map.put(@new_plugin, plugin)
      }

      revised =
        content
        |> String.replace(~r/^\[marketplaces\.ehos-tools\]/m, "[marketplaces.ehos-app]")
        |> String.replace(
          ~r/^\[plugins\."ehos-app@ehos-tools"\]/m,
          ~s([plugins."ehos-app@ehos-app"])
        )
        |> String.replace(~r/^ref = "#{@old_ref}"/m, ~s(ref = "#{pin.commit}"))

      if Toml.decode(revised) == {:ok, expected}, do: {:ok, revised}, else: :manual
    else
      _other -> :manual
    end
  end
end
