defmodule EhosDesign.MixProject do
  use Mix.Project

  @version "0.2.0"

  def project do
    [
      app: :ehos_design,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      # LiveView's compiler writes the manifest of the colocated hook `EhosDesign.Components`
      # carries, `phoenix-colocated/ehos_design`, which a host imports (eh-os D-86).
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      aliases: aliases(),
      deps: deps()
    ]
  end

  # LiveView is required, not optional: the colocated hook needs its compiler in this project's
  # `compilers`, which a host without it could not run. Every host that takes the package from
  # Mix is a Phoenix application, with LiveView already.
  defp deps do
    [
      {:phoenix_live_view, "~> 1.1"},
      {:lazy_html, "~> 0.1", only: :test}
    ]
  end

  def cli, do: [preferred_envs: [check: :test]]

  # An application with no processes: it is one so that a release carries its `priv/`, and a
  # host serves the fonts with `Plug.Static, from: {:ehos_design, "priv/static"}`.
  def application, do: []

  defp aliases do
    [
      check: [
        "format --check-formatted",
        "compile --force --warnings-as-errors",
        "test"
      ]
    ]
  end
end
