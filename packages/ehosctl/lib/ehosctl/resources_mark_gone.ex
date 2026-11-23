defmodule Ehosctl.ResourcesMarkGone do
  @moduledoc """
  `ehosctl resources mark-gone NAME`: marks a database outside the installation gone for good,
  `gone: true` on its entry of `dataResources.external`, and installs the EHOS that runs again
  (eh-os D-192). EHOS then checks nothing there, and the teardown of an ephemeral environment bound
  to it drops nothing there and lets the environment's name go. The entry stays listed until no
  resource binding names it; `ehosctl resources remove-database` then takes it away.

  It runs as `Ehosctl.ExternalDatabaseList` says. It refuses a database marked gone already, and
  EHOS's check before the upgrade refuses one that an environment that is not removed is bound to.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.ExternalDatabaseList
  alias Ehosctl.Output
  alias Ehosctl.Refusal
  alias EhosPlatform.Shell

  @impl Ehosctl.Command
  def name, do: :"mark-gone"

  @impl Ehosctl.Command
  def plane, do: :platform

  @impl Ehosctl.Command
  def group, do: :installation

  @impl Ehosctl.Command
  def summary, do: "Mark a database outside the installation gone for good."

  @impl Ehosctl.Command
  def spec,
    do:
      ExternalDatabaseList.spec(
        "Mark a database outside the installation gone for good, when its provider deleted it " <>
          "or it does not answer again. EHOS then checks nothing there, and the removal of an " <>
          "ephemeral environment bound to it drops nothing there. ehosctl installs the version " <>
          "of EHOS that runs again from its release, through the tunnel to the server. EHOS " <>
          "refuses the mark while an environment that is not removed is bound to the database. " <>
          "Needs GHCR_TOKEN. For developing EHOS only.",
        ["The name of the resource, as `ehosctl resources list` shows it."]
      )

  @doc """
  Marks the database gone. `opts` as `Ehosctl.Install.call/3`'s: `:install` is the module that does
  the platform's work, `EhosPlatform.Install` by default.
  """
  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], parsed, opts) do
    ExternalDatabaseList.changed(parsed, opts, %{
      listed: &marked/3,
      preview: &preview/3,
      question: fn entry, name, version ->
        "Mark #{entry["name"]} gone, and install EHOS #{version} on #{name} again?"
      end,
      done: &done/3
    })
  end

  defp marked(_running, %{"gone" => true} = entry, name),
    do:
      {:error, :invalid,
       "#{name} marks the database #{Refusal.shown(entry["name"])} gone already." <>
         Output.offered(
           " Once no resource binding names it, run `ehosctl resources remove-database " <>
             "#{Shell.word(entry["name"])} --installation #{Shell.word(name)}`."
         ) <> " ehosctl changed nothing."}

  defp marked(running, entry, _name),
    do:
      {:ok,
       Enum.map(
         running,
         &if(&1["name"] == entry["name"], do: Map.put(&1, "gone", true), else: &1)
       )}

  defp preview(entry, name, version) do
    Output.lines([
      "ehosctl marks the database #{entry["name"]} outside the installation gone for good on " <>
        "#{name}, which runs EHOS #{version}:",
      Output.values([
        {"Server", ExternalDatabaseList.server(entry)},
        {"Database", entry["database"]}
      ]),
      "EHOS then checks nothing there. The removal of an ephemeral environment bound to it " <>
        "drops nothing there, and deletes the passwords of its roles. The audit record names " <>
        "the schema and the roles that each removal leaves.",
      "ehosctl installs EHOS #{version} again with the mark in its list."
    ])
  end

  defp done(entry, name, _opts) do
    database = Shell.word(entry["name"])
    installation = Shell.word(name)

    {:ok,
     Output.lines([
       Output.outcome(
         :done,
         "#{name} marks the database #{entry["name"]} outside the installation gone for good."
       ),
       "",
       "Once the resource shows no binding, take it out of the list.",
       Output.next([
         "ehosctl resources show #{database} --installation #{installation}",
         "ehosctl resources remove-database #{database} --installation #{installation}"
       ])
     ])}
  end
end
