defmodule EhosDesign do
  @moduledoc """
  The EmpoweredHouse design system, as files a Phoenix application builds its styles from, and
  the components built on them, in `EhosDesign.Components`.

  It ships, under `priv/`:

    * `priv/css/colors_and_type.css`, the design system's tokens, as Claude Design has them
      but for one recorded change, and `priv/css/SOURCE.md`, which says where they came from;
    * `priv/css/components/`, the look of each component, as Claude Design has it, recorded in
      the same `SOURCE.md`;
    * `priv/css/ehos_design.css`, the tokens mapped to Tailwind CSS 4 and daisyUI 5, with the
      components' stylesheets;
    * `priv/static/ehos_design/fonts/`, Albert Sans and JetBrains Mono at 400 and 500, which a
      host serves with `plug Plug.Static, at: "/", from: {:ehos_design, "priv/static"},
      only: ~w(ehos_design)`.

  The package's README says how to use each, and how the tokens are refreshed.
  """

  @doc """
  What a release of this `ehos_design` says about itself in its `release.json`, schema
  `ehos.release/v1` ([releases](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/releases.md)):
  its version and the `commit` it is made from, which only the caller knows. A design system
  produces and accepts none of the interfaces between EHOS's components.
  `mix ehos_design.release_file`, an alias of this package's own, writes it.

      iex> release = EhosDesign.release("0123456789abcdef0123456789abcdef01234567")
      iex> {release["component"], release["produces"], release["requires"]}
      {"ehos_design", [], %{}}
  """
  @spec release(String.t()) :: %{String.t() => term()}
  def release(commit) when is_binary(commit) do
    %{
      "schema" => "ehos.release/v1",
      "component" => "ehos_design",
      "version" => to_string(Application.spec(:ehos_design, :vsn)),
      "commit" => commit,
      "produces" => [],
      "accepts" => [],
      "requires" => %{}
    }
  end
end
