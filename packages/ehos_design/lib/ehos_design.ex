defmodule EhosDesign do
  @moduledoc """
  The EmpoweredHouse design system, as files a Phoenix application builds its styles from.

  The package has no code to call. It ships, under `priv/`:

    * `priv/css/colors_and_type.css`, the design system's tokens, as Claude Design has them
      but for one recorded change, and `priv/css/SOURCE.md`, which says where they came from;
    * `priv/css/ehos_design.css`, the tokens mapped to Tailwind CSS 4 and daisyUI 5;
    * `priv/static/ehos_design/fonts/`, Albert Sans and JetBrains Mono at 400 and 500, which a
      host serves with `plug Plug.Static, at: "/", from: {:ehos_design, "priv/static"},
      only: ~w(ehos_design)`.

  The package's README says how to use each, and how the tokens are refreshed.
  """
end
