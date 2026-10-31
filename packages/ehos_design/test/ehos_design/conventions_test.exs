defmodule EhosDesign.ConventionsTest do
  @moduledoc """
  ehos_design held to T-20 by the repository's `EhosTools.ConventionsCase`: only a behaviour's
  implementation reaches a program, the network, the environment, the home directory, the
  terminal, the clock or a wait.
  """

  use EhosTools.ConventionsCase, async: true, app: :ehos_design
end
