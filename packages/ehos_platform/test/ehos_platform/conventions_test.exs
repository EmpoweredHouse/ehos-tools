defmodule EhosPlatform.ConventionsTest do
  @moduledoc """
  ehos_platform held to T-20 by the repository's `EhosTools.ConventionsCase`: only a behaviour's
  implementation reaches a program, the network, the environment, the home directory, the
  terminal, the clock or a wait.
  """

  use EhosTools.ConventionsCase,
    async: true,
    app: :ehos_platform,
    # Both read the system's home directory through `System.user_home!/0`: the server for a key
    # recorded from `~/` when `HOME` gives none it can use, the provider for `clouds.yaml` when the
    # caller gives no `:clouds_yaml`. Moving that behind `EhosPlatform.Env` changes a released
    # library eh-os pins, so it is a change of its own, and this list names them until it lands
    # (ehos-tools#690).
    allowed: [EhosPlatform.Server, EhosPlatform.Server.Provider]
end
