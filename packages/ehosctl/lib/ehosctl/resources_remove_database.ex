defmodule Ehosctl.ResourcesRemoveDatabase do
  @moduledoc """
  `ehosctl resources remove-database NAME`: takes a database outside the installation out of
  `dataResources.external`, installs the EHOS that runs again, and then deletes the Secret of its
  managing role, `ehos-external-<name>` in `ehos-data`, when ehosctl made it (eh-os D-187, D-192,
  T-29). EHOS keeps the resource registered, not listed, and its data stays on the database.

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
          "stays. Needs GHCR_TOKEN. For developing EHOS only.",
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
        {"Server", "#{entry["host"]}:#{entry["port"]}"},
        {"Database", entry["database"]},
        {"Managing role", "In the Secret #{secret(entry)}"}
      ]),
      "EHOS refuses it while a resource binding names the database. The data on the database " <>
        "stays.",
      "ehosctl installs EHOS #{version} again without the database, then deletes the Secret."
    ])
  end

  # After the install: the database is out of the list whatever happens to its Secret.
  defp done(entry, name, opts) do
    platform = Keyword.get(opts, :install, EhosPlatform.Install)

    deleted =
      platform.delete_external_secret(
        Ehosctl.Install.platform_options(name, opts) ++
          [progress: &Ehosctl.PlatformReport.progress/1],
        entry["name"]
      )

    Output.lines([
      Output.outcome(
        :done,
        "#{name} no longer lists the database #{entry["name"]} outside the installation."
      ),
      secret_said(deleted, entry)
    ])
  end

  defp secret_said({:ok, :deleted}, entry),
    do: "ehosctl deleted the Secret #{secret(entry)} of its managing role."

  defp secret_said({:ok, :absent}, entry),
    do: "The Secret #{secret(entry)} was not there."

  defp secret_said({:ok, {:kept, why}}, entry),
    do: "ehosctl kept the Secret #{secret(entry)}, which it did not make: #{why}."

  defp secret_said({:error, message}, entry) do
    "ehosctl could not delete the Secret #{secret(entry)}: " <>
      to_string(message) <>
      " Delete it with `kubectl -n #{ExternalDatabases.namespace()} delete secret " <>
      "#{Shell.word(entry["managingRoleSecret"])}`."
  end

  defp secret(entry), do: "#{ExternalDatabases.namespace()}/#{entry["managingRoleSecret"]}"
end
