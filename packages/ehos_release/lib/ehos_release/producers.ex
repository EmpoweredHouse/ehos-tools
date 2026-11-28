defmodule EhosRelease.Producers do
  @moduledoc """
  The three repositories a pin can name, and the tag prefix each pinned thing is released under
  (eh-os D-205, "Between releases"; T-34). A release accepts a pin only when a protected tag of
  one of those prefixes names it.

  Data, not configuration of the caller's: a caller could otherwise name its own prefix for a
  pin. A path is matched exactly, or by its start when it ends in `/`: ehos_contract tags all its
  packages with one `v` tag.
  """

  @producers %{
    "empoweredhouse/ehos-tools" => [
      {"packages/ehos_app", ["ehos_app-v"]},
      {"packages/ehos_design", ["ehos_design-v"]},
      {"packages/ehos_diagrams", ["ehos_diagrams-v"]},
      {"packages/ehos_platform", ["ehos_platform-v"]},
      {"packages/ehos_tunnel", ["ehos_tunnel-v"]},
      {"packages/ehos_release", ["ehos_release-v"]},
      # T-27: a utility service's pipeline is released by ehosctl's tag.
      {".github/workflows/ehos-service.yml", ["v"]},
      {".github/workflows/ehos-release.yml", ["ehos_release-v"]},
      {".github/workflows/ehos-pins.yml", ["ehos_release-v"]},
      # The marketplace serves the plugins of the tag a `ref` names: ehos-dev's for eh-os,
      # ehos-tools and ehos_contract, ehos-app's for an application.
      {".claude-plugin/marketplace.json", ["ehos-dev-v", "ehos-app-v"]}
    ],
    "empoweredhouse/ehos_contract" => [
      {"packages/", ["v"]},
      {".claude-plugin/marketplace.json", ["ehos-contract-plugin-v"]}
    ],
    "empoweredhouse/eh-os" => [
      {"", ["v"]}
    ]
  }

  @doc """
  Whether a pin into `repository` is one D-205 checks: a repository of the three, in any case,
  as GitHub reads its names.

      iex> EhosRelease.Producers.producer?("EmpoweredHouse/ehos-tools")
      true

      iex> EhosRelease.Producers.producer?("actions/checkout")
      false
  """
  @spec producer?(String.t()) :: boolean()
  def producer?(repository), do: Map.has_key?(@producers, String.downcase(repository))

  @doc """
  Whether `text` names a producer as `owner/name`, in any case, as a URL does.

      iex> EhosRelease.Producers.any_named?("https://raw.githubusercontent.com/EmpoweredHouse/ehos-tools/main/x")
      true
  """
  @spec any_named?(String.t()) :: boolean()
  def any_named?(text) do
    text = String.downcase(text)
    Enum.any?(Map.keys(@producers), &String.contains?(text, &1))
  end

  @doc """
  The tag prefixes a pin of `path` in `repository` is released under, or `:error` when the
  repository releases nothing from there.

      iex> EhosRelease.Producers.prefixes("EmpoweredHouse/ehos-tools", "packages/ehos_platform")
      {:ok, ["ehos_platform-v"]}

      iex> EhosRelease.Producers.prefixes("EmpoweredHouse/ehos_contract", "packages/ehos_contract_graph")
      {:ok, ["v"]}

      iex> EhosRelease.Producers.prefixes("EmpoweredHouse/ehos-tools", "packages/review")
      :error
  """
  @spec prefixes(String.t(), String.t()) :: {:ok, [String.t()]} | :error
  def prefixes(repository, path) do
    @producers
    |> Map.get(String.downcase(repository), [])
    |> Enum.find(fn {pattern, _prefixes} -> matches?(pattern, path) end)
    |> case do
      {_pattern, prefixes} -> {:ok, prefixes}
      nil -> :error
    end
  end

  defp matches?(pattern, path) do
    if String.ends_with?(pattern, "/"),
      do: String.starts_with?(path, pattern),
      else: pattern == path
  end
end
