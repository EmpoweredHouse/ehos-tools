defmodule Ehosctl.Services do
  @moduledoc """
  `ehosctl services list | agree | withdraw | agree-hosts | withdraw-hosts`: which application may
  call which utility service, in each environment, as the environment tabs agree (eh-os
  [`docs/agreements-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/agreements-api.md#service-agreements),
  D-175). Listing needs `ehos.application.deploy`, `ehos.application.register` or
  `ehos.release.approve` for the application named there; agreeing and withdrawing need
  `ehos.application.deploy` for the utility service there; agreeing and withdrawing for the
  application's side, to the hosts outside the installation that the service names there, need
  `ehos.release.approve` for the application there. The work is `Ehosctl.Agreements`'s.

  An application asks in its `ehos.yaml` to call a utility service. While a service agreement
  holds, EHOS gives the application the address of the service, and the network lets only that
  application's pods reach it. Where the service names a host outside, a service agreement holds
  only once the application's side agrees too.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Agreements

  @impl Ehosctl.Command
  def name, do: :services

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def spec, do: Agreements.services_spec()

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([action], parsed, opts), do: Agreements.services(action, parsed, opts)
end
