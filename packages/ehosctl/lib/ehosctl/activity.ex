defmodule Ehosctl.Activity do
  @moduledoc """
  `ehosctl activity [--limit N]`: what was done in the person's name or their agents', allowed and
  refused, newest first, as the console's My activity page shows it (eh-os
  [`docs/audit-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/audit-api.md),
  D-82). It needs no capability: it reads only the person's own rows, and follows their pages up
  to `--limit` rows.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Audit
  alias Ehosctl.Output

  @impl Ehosctl.Command
  def name, do: :activity

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def group, do: :access

  @impl Ehosctl.Command
  def summary, do: "List the decisions made in your name."

  @impl Ehosctl.Command
  def spec,
    do: [
      about:
        "List the decisions made in your name or in the name of your agents, allowed and " <>
          "refused.",
      options: [limit: Audit.limit_option()],
      flags: Output.json_flag()
    ]

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], parsed, opts), do: Audit.listed("/api/v1/me/activity", parsed.options.limit, opts)
end
