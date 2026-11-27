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
               version: "0.14.0",
               commit: "2d23563b63996d3909465ff04586c829b49fa854"
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
               version: "0.16.0",
               commit: "c0563c9659f52e0b3546d25bdd54d98542c4f066"
             }
           ]
           |> Enum.map(&Map.put(&1, :ref, &1.tag <> to_string(Version.parse!(&1.version))))

  @doc "Returns plugin identities, release versions, marketplace locations and source commits."
  @spec all() :: [map()]
  def all, do: @plugins
end
