defmodule EhosApp do
  @moduledoc """
  What an application needs to run on EHOS, as a dependency it keeps.

  Today that is the installer, `mix ehos_app.install`, which `ehosctl init` runs on a
  fresh Phoenix project. The runtime side (verifying EHOS credentials, the health and
  specification endpoints) lands here as EHOS defines it, so an application upgrades
  it the same way it upgraded everything else: `mix igniter.upgrade ehos_app`.
  """
end
