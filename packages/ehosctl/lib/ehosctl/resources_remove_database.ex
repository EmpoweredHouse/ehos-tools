defmodule Ehosctl.ResourcesRemoveDatabase do
  @moduledoc """
  `ehosctl resources remove-database NAME`: takes a database outside the installation out of
  `dataResources.external`, installs the EHOS that runs again, and then deletes the Secret of its
  managing role, `ehos-external-<name>` in `ehos-data`, when ehosctl made it (eh-os D-192, T-29).
  EHOS keeps the resource registered, not listed, and its data stays on the database.

  It runs as `Ehosctl.ExternalDatabaseList` says. EHOS's check before the upgrade refuses the
  change while a resource binding names the database, before Helm changes anything; for a
  database that is gone for good, `ehosctl resources mark-gone` lets those bindings go first.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.ExternalDatabaseList
  alias Ehosctl.Output
  alias EhosPlatform.ExternalDatabases
  alias EhosPlatform.Shell

  @impl Ehosctl.Command
  def name, do: :"remove-database"

  @impl Ehosctl.Command
  def plane, do: :platform

  @impl Ehosctl.Command
  def group, do: :installation

  @impl Ehosctl.Command
  def summary, do: "Take a database outside the installation out of the list."

  @impl Ehosctl.Command
  def spec,
    do:
      ExternalDatabaseList.spec(
        "Take a database outside the installation out of the list of resources, and delete " <>
          "the Secret of its managing role that ehosctl made. ehosctl installs the version of " <>
          "EHOS that runs again from its release, through the tunnel to the server. EHOS " <>
          "refuses it while a resource binding names the database. The data on the database " <>
          "stays. Needs GHCR_TOKEN.",
        ["The name of the resource, as `ehosctl resources list` shows it."]
      )

  @doc """
  Takes the database out of the list. `opts` as `Ehosctl.Install.call/3`'s: `:install` is the
  module that does the platform's work, `EhosPlatform.Install` by default.
  """
  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], parsed, opts) do
    ExternalDatabaseList.changed(parsed, opts, %{
      listed: fn running, entry, _name -> {:ok, List.delete(running, entry)} end,
      preview: &preview/3,
      question: fn entry, name, version ->
        "Take #{entry["name"]} out of the list, install EHOS #{version} on #{name} again, and " <>
          "delete the Secret of its managing role?"
      end,
      done: &done/3
    })
  end

  defp preview(entry, name, version) do
    Output.lines([
      "ehosctl takes the database #{entry["name"]} outside the installation out of the list " <>
        "of #{name}, which runs EHOS #{version}:",
      Output.values([
        {"Server", ExternalDatabaseList.server(entry)},
        {"Database", entry["database"]},
        {"Managing role", "In the Secret #{secret(entry["name"])}"}
      ]),
      "EHOS refuses it while a resource binding names the database. The data on the database " <>
        "stays.",
      "ehosctl installs EHOS #{version} again without the database, then deletes the Secret."
    ])
  end

  # After the install: the database is out of the list whatever happens to its Secret.
  defp done(entry, name, opts) do
    database = entry["name"]
    out = "#{name} no longer lists the database #{database} outside the installation."

    case secret_deleted(database, name, opts, out) do
      {:ok, :absent} ->
        {:ok,
         Output.lines([
           Output.outcome(:done, out),
           "The Secret #{secret(database)} was not there."
         ])}

      {:ok, said} ->
        {:ok, Output.lines([Output.outcome(:done, out), said])}

      error ->
        error
    end
  end

  defp secret_deleted(database, name, opts, out) do
    platform = Keyword.get(opts, :install, EhosPlatform.Install)

    deleted =
      platform.delete_external_secret(
        Ehosctl.Install.platform_options(name, opts) ++
          [progress: &Ehosctl.PlatformReport.progress/1],
        database
      )

    case deleted do
      {:ok, :deleted} ->
        {:ok, "ehosctl deleted the Secret #{secret(database)} of its managing role."}

      {:ok, :absent} ->
        {:ok, :absent}

      {:ok, {:kept, why}} ->
        {:ok, "ehosctl kept the Secret #{secret(database)}: #{why}."}

      {:error, message} ->
        {:error, :failed,
         message
         |> EhosPlatform.Failure.within(
           "#{out} ehosctl could not delete the Secret #{secret(database)} of its managing " <>
             "role:\n",
           ""
         )
         |> Ehosctl.PlatformReport.failure()
         |> Ehosctl.Failure.with_to_do(
           "EHOS runs without the database. Delete the Secret once the server answers:",
           [
             "kubectl --kubeconfig #{kubeconfig(name, opts)} --context " <>
               "#{Shell.word("ehos-" <> name)} -n #{ExternalDatabases.namespace()} delete " <>
               "secret #{Shell.word(ExternalDatabases.secret_name(database))}"
           ]
         )}
    end
  end

  defp kubeconfig(name, opts),
    do: Shell.word(Path.join([Ehosctl.Server.home(opts), name, "kubeconfig"]))

  defp secret(database),
    do: "#{ExternalDatabases.namespace()}/#{ExternalDatabases.secret_name(database)}"
end
