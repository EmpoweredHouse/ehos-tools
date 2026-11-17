defmodule EhosApp.PluginPins do
  @moduledoc "The plugin releases configured for applications in Claude Code and Codex."

  @plugins [
             %{
               name: "ehos-app",
               marketplace: "ehos-app",
               formerly: "ehos-tools",
               repo: "EmpoweredHouse/ehos-tools",
               path: ".claude-plugin/ehos-app.json",
               tag: "ehos-app-v",
               version: "0.14.0",
               commit: "2d23563b63996d3909465ff04586c829b49fa854"
             },
             %{
               name: "eh-os-contract",
               marketplace: "eh-os-contract",
               repo: "EmpoweredHouse/eh-os-contract",
               tag: "eh-os-contract-plugin-v",
               version: "0.14.3",
               commit: "f9242abf83d33bea76f2db52b28bbaba584769a8"
             }
           ]
           |> Enum.map(&Map.put(&1, :ref, &1.tag <> to_string(Version.parse!(&1.version))))

  @doc "Returns plugin identities, release versions, marketplace locations and source commits."
  @spec all() :: [map()]
  def all, do: @plugins
end
