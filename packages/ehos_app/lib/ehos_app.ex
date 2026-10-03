defmodule EhosApp do
  @moduledoc """
  What an application needs to run on EHOS, as a dependency it keeps.

  Today that is the installer, `mix ehos_app.install`, which `ehosctl init` runs on a
  fresh Phoenix project. What it writes follows what EHOS decided: `ehos.yaml`, the
  health endpoints, the variables an application is given at start, and the credential
  check in front of the contracts. An application gets a later version by moving its
  dependency to it and running `mix ehos_app.install` again (ehos-tools T-02).
  """
end
