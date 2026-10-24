defmodule Ehosctl.Mail do
  @moduledoc """
  `ehosctl mail agreements | agree | withdraw`: how far each application's workload may send mail
  through EHOS, in each environment, as the console's Installation page agrees (eh-os
  [`docs/agreements-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/agreements-api.md#mail-d-140),
  D-140). Each needs `ehos.mail.manage` at the platform; the work is `Ehosctl.Agreements`'s.

  An application asks in its `ehos.yaml` to write to the company's people only (`internal`) or to
  any address (`external`), and names the domains where the answers go. EHOS sends what it asks
  only once someone agrees, per environment, and never further than both the agreement and the
  deployment in force there allow.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.{Agreements, Refusal}

  @impl Ehosctl.Command
  def name, do: :mail

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def spec, do: Agreements.mail_spec()

  @doc false
  # The console's words for whom an application writes to and where the answers go (eh-os
  # `Ehos.Applications.EhosYaml.Mail.asked/1`), the domains sorted: the deploy review's and the
  # agreements' alike.
  @spec whom(map()) :: String.t()
  def whom(%{"level" => level, "reply_domains" => domains}) do
    whom =
      if level == "internal", do: "to people in EHOS's directory only", else: "to any address"

    case domains do
      [] -> whom
      domains -> whom <> ", with replies to " <> listed(domains)
    end
  end

  @doc false
  @spec listed([String.t()]) :: String.t()
  def listed(domains), do: domains |> Enum.sort() |> Enum.map_join(", ", &Refusal.shown/1)

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([action], parsed, opts), do: Agreements.mail(action, parsed, opts)
end
