defmodule EhosTunnel.ConventionsTest do
  @moduledoc """
  ehos_tunnel held to T-20 by the repository's `EhosTools.ConventionsCase`: only a behaviour's
  implementation reaches a program, the network, the environment, the home directory, the
  terminal, the clock or a wait.
  """

  use EhosTools.ConventionsCase,
    async: true,
    app: :ehos_tunnel,
    # Waits 100 ms before it accepts again when the system is out of descriptors or memory, as
    # ranch's acceptor does; a test cannot bring that about, and nothing replaces the wait.
    allowed: [EhosTunnel.Listener]
end
