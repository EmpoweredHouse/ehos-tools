defmodule Ehosctl.ConventionsTest do
  @moduledoc """
  ehosctl held to T-20 by the repository's `EhosTools.ConventionsCase`: only a behaviour's
  implementation reaches a program, the network, the environment, the home directory, the
  terminal, the clock or a wait.
  """

  use EhosTools.ConventionsCase,
    async: true,
    app: :ehosctl,
    # Runs while Mix compiles ehosctl, before any configuration chooses an implementation: it
    # reads the commit and the build's variables to stamp the version.
    allowed: [Ehosctl.Build]
end
