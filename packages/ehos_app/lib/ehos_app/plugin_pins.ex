defmodule EhosApp.PluginPins do
  @moduledoc "The plugin releases configured for applications in Claude Code and Codex."

  @plugin "ehos-app"

  @plugins [
             %{
               name: @plugin,
               marketplace: @plugin,
               former: %{
                 name: @plugin,
                 marketplace: "ehos-tools",
                 repo: "EmpoweredHouse/ehos-tools",
                 tag: @plugin <> "-v"
               },
               repo: "EmpoweredHouse/ehos-tools",
               path: ".claude-plugin/ehos-app.json",
               tag: @plugin <> "-v",
               version: "0.15.0",
               commit: "d45f0cae0a2200328f2c3bc8131eda3500e9ce94"
             },
             %{
               name: "ehos-contract",
               marketplace: "ehos-contract",
               former: %{
                 name: "eh-os-contract",
                 marketplace: "eh-os-contract",
                 repo: "EmpoweredHouse/eh-os-contract",
                 tag: "eh-os-contract-plugin-v"
               },
               repo: "EmpoweredHouse/ehos_contract",
               tag: "ehos-contract-plugin-v",
               version: "0.16.1",
               commit: "3c13df6bd88116ed350a8c7eb3e65928d897947c"
             }
           ]
           |> Enum.map(&Map.put(&1, :ref, &1.tag <> to_string(Version.parse!(&1.version))))

  @doc "Returns plugin identities, release versions, marketplace locations and source commits."
  @spec all() :: [map()]
  def all, do: @plugins
end
