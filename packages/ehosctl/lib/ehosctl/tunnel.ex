defmodule Ehosctl.Tunnel do
  @moduledoc """
  The client of the data gateway that a data session's tunnels go through: `EhosTunnel.Client`,
  from the `ehos_tunnel` package (eh-os D-180), chosen when `ehosctl` is compiled, as each of its
  ways out is (T-20). Tests replace it with a mock.
  """

  @impl_module Application.compile_env!(:ehosctl, [__MODULE__, :impl])

  @doc "The implementation of `EhosTunnel.Client` the configuration chose."
  @spec current() :: module()
  def current, do: @impl_module
end
