defmodule Ehosctl.ExternalDatabaseList do
  @moduledoc """
  What `ehosctl resources mark-gone` and `ehosctl resources remove-database` share: each changes
  one entry of the running EHOS's `dataResources.external` and installs that EHOS again (eh-os
  D-192, T-29). `ehosctl resources add-database` shares its steps that ask, render and check the
  release again. Each runs on the platform plane, through the kubeconfig `ehosctl server tunnel`
  wrote, never through EHOS's API, in this order, and writes nothing before step 6:

    1. It asks only where someone can answer: standard input is a terminal, or `--yes` is given.
    2. It reads what runs (`Ehosctl.Install.installed/2`), and refuses when nothing runs, when the
       EHOS that runs is before `Ehosctl.Install.external_since/0`, or when the list does not name
       the database.
    3. It changes the list as the command says (`t:change/0`'s `:listed`), which may refuse.
    4. It reads the release of the version that runs from GitHub (`Ehosctl.EhosRelease`), refuses,
       as `install` does, when what runs is not that published release's image and chart, and
       renders the chart that runs with the new list, so the chart's own refusals come first.
    5. It prints what changes, asks before it writes, unless `--yes`, and reads the release's
       deployed revision again: one that moved since step 2 is refused.
    6. It installs the version that runs again, as `upgrade` does (`Ehosctl.Install.install/4`),
       with every other setting kept from what runs (`Ehosctl.Install.kept/3`). EHOS's check
       before the upgrade then refuses, before Helm changes anything, what the chart alone cannot
       see: a database that a resource binding names leaving the list (eh-os D-187), and one
       marked gone while an environment that is not removed is bound to it (eh-os D-192).
    7. It runs the command's step after the install (`t:change/0`'s `:done`), which says what
       changed.
  """

  alias Ehosctl.EhosRelease
  alias Ehosctl.Install
  alias Ehosctl.Output
  alias Ehosctl.Refusal

  @typedoc """
  What a command does to the list: `listed` takes the list that runs, the entry the command names
  and the installation, and gives the new list or a refusal; `preview` and `question` take the
  entry, the installation and the version that runs, and give what is printed before and asked;
  `done` takes the entry, the installation and the command's options, runs the command's step
  after the install, and gives what it says or why it failed.
  """
  @type change :: %{
          required(:listed) => ([map()], map(), String.t() ->
                                  {:ok, [map()]} | {:error, atom(), String.t()}),
          required(:preview) => (map(), String.t(), String.t() -> Output.text()),
          required(:question) => (map(), String.t(), String.t() -> String.t()),
          required(:done) => (map(), String.t(), keyword() ->
                                {:ok, String.t()} | {:error, atom(), term()}),
          optional(:absent) => (String.t(), String.t(), keyword() -> Ehosctl.Command.result())
        }

  @doc "The options of a command that changes an entry: the installation, and `--yes`."
  @spec spec(String.t(), [String.t()]) :: keyword()
  def spec(about, name_help) do
    [
      about: about,
      args: [name: [value_name: "NAME", required: true, help: Enum.join(name_help, " ")]],
      options: [
        installation: [
          long: "--installation",
          value_name: "NAME",
          help:
            "The installation of the server. By default EHOSCTL_INSTALLATION, else the current " <>
              "installation, else trial."
        ]
      ],
      flags: [yes: [long: "--yes", help: "Do not ask for confirmation."]]
    ]
  end

  @doc "Changes the entry `parsed` names, as `change` says, and installs EHOS again."
  @spec changed(Optimus.ParseResult.t(), keyword(), change()) :: Ehosctl.Command.result()
  def changed(parsed, opts, change) do
    with {:ok, name} <- Ehosctl.Server.installation(parsed.options[:installation], opts),
         :ok <- answerable(parsed),
         {:ok, installed} <- Install.installed(name, opts),
         :ok <- Install.settled(installed, name, opts),
         {:ok, version} <- running_version(installed.running, name),
         running = installed.external_databases || [],
         {:ok, entry} <- entry(running, parsed.args.name, name),
         {:ok, listed} <- change.listed.(running, entry, name),
         {:ok, release, described} <- EhosRelease.find(version, opts),
         {:ok, wanted} <- EhosRelease.installable(release, described),
         :ok <- Install.may_install(installed.running, wanted, name),
         :ok <- Install.host_kept(nil, installed.host, name, opts, &upgrade_first(name, &1)),
         :ok <- readable_mail(installed.mail, name),
         {:ok, kept} <-
           Install.kept(parsed, %{installed | external_databases: listed}, version),
         env = Ehosctl.SystemEnv.current().all(),
         # The mail is kept as it runs, as `resources add-database` keeps it.
         :ok <- Install.password_given(kept[:mail], installed.mail, env, true),
         :ok <- rendered(name, listed, installed, env, opts, "the list"),
         :ok <- previewed(change.preview.(entry, name, version), installed, kept[:mail]),
         :ok <- asked(change.question.(entry, name, version), parsed),
         :ok <- unmoved(installed, name, opts),
         {:ok, done} <-
           Install.install(
             name,
             wanted,
             installed.host,
             opts |> Keyword.merge(kept) |> Keyword.put(:keep_smtp_password, true)
           ) do
      Install.warn_failed_before(installed)

      with {:ok, said} <- change.done.(entry, name, opts),
           do: {:ok, %{done | text: Output.lines([said, "", done.text])}}
    end
  end

  @doc "`:ok` where someone can answer the question: standard input is a terminal, or `--yes`."
  @spec answerable(Optimus.ParseResult.t()) :: :ok | {:error, :invalid, String.t()}
  def answerable(%{flags: flags}) do
    if flags[:yes] == true or Ehosctl.Terminal.current().input_terminal?(),
      do: :ok,
      else:
        {:error, :invalid,
         "Standard input is not a terminal, so ehosctl cannot ask before it writes. Give --yes " <>
           "to write without a question. ehosctl changed nothing."}
  end

  defp running_version(:none, name),
    do:
      {:error, :invalid,
       "#{name} runs no EHOS, so it lists no database outside the installation. ehosctl " <>
         "changed nothing."}

  defp running_version(%{"version" => version}, name) do
    if Install.external_databases?(version),
      do: {:ok, version},
      else:
        {:error, :invalid,
         "#{name} runs EHOS #{Refusal.shown(version)}, which lists no database outside the " <>
           "installation. ehosctl changed nothing."}
  end

  defp running_version(_unrecorded, name),
    do:
      {:error, :invalid,
       "#{name} runs an EHOS whose version ehosctl cannot read from the cluster. Run " <>
         "`ehosctl upgrade --installation #{name}` first. ehosctl changed nothing."}

  defp entry(running, database, name) do
    case Enum.find(running, &(&1["name"] == database)) do
      nil ->
        {:error, :invalid,
         "#{name} lists no database #{Refusal.shown(database)} outside the installation." <>
           Output.offered(
             " Run `ehosctl resources list --installation #{EhosPlatform.Shell.word(name)}` to " <>
               "see the resources."
           ) <> " ehosctl changed nothing."}

      entry ->
        {:ok, entry}
    end
  end

  @doc "Where the server of `entry` is, `host:port`, the chart's port when the entry gives none."
  @spec server(map()) :: String.t()
  def server(entry), do: "#{entry["host"]}:#{Map.get(entry, "port") || 5432}"

  @doc "What to run first when the host is not the one EHOS runs with."
  @spec upgrade_first(String.t(), String.t()) :: String.t()
  def upgrade_first(name, host_option),
    do: "run `ehosctl upgrade --installation #{name} #{host_option}` first"

  @doc """
  `:ok` unless EHOS on `name` sends mail through settings ehosctl did not write, which an install
  could not keep without a word.
  """
  @spec readable_mail(term(), String.t()) :: :ok | {:error, :invalid, String.t()}
  def readable_mail(:unreadable, name),
    do:
      {:error, :invalid,
       "EHOS on #{name} sends mail through settings that ehosctl did not write " <>
         "(governance.mail in its Helm release). Run `ehosctl install --installation #{name}` " <>
         "with --smtp-host and --mail-from, or with --no-mail, first. ehosctl changed nothing."}

  def readable_mail(_mail, _name), do: :ok

  @doc """
  Renders the chart that runs on `name` with `listed`, so the chart's own refusals come before
  anything is written; `what` names what the chart refused, such as "the database".
  """
  @spec rendered(String.t(), [map()], map(), map(), keyword(), String.t()) ::
          :ok | {:error, :failed, term()}
  def rendered(name, listed, installed, env, opts, what) do
    platform = Keyword.get(opts, :install, EhosPlatform.Install)

    rendered =
      platform.render_running(
        Install.platform_options(name, opts) ++
          [
            external_databases: listed,
            external_under_development: installed.external_under_development,
            token: env["GHCR_TOKEN"],
            username: env["GHCR_USERNAME"],
            progress: &Ehosctl.PlatformReport.progress/1
          ]
      )

    case rendered do
      {:ok, _manifests} ->
        :ok

      {:error, message} ->
        {:error, :failed,
         message
         |> EhosPlatform.Failure.map_text(&String.trim_trailing/1)
         |> EhosPlatform.Failure.within(
           "The chart of EHOS refused #{what}, or could not be rendered. ehosctl changed " <>
             "nothing.\n",
           ""
         )
         |> Ehosctl.PlatformReport.failure()}
    end
  end

  @doc "What changes, on stdout before anything is written, and each warning the install gives."
  @spec previewed(Output.text(), map(), term()) :: :ok
  def previewed(preview, installed, mail) do
    Output.result(%{text: preview, json: nil}, false)
    Install.warn_left_out(installed)
    Install.warn_relay(mail)
  end

  defp asked(question, parsed) do
    case Install.confirmed(question, parsed) do
      :ok -> :ok
      :not_confirmed -> {:ok, %{text: "ehosctl changed nothing.", json: nil}}
    end
  end

  @doc """
  `:ok` when the Helm release on `name` is still at the revision `installed` read: a change another
  command made since would be lost under this install. One that starts between this read and the
  pending revision Helm makes is not caught: Helm has no compare-and-set.
  """
  @spec unmoved(map(), String.t(), keyword()) :: :ok | {:error, :failed, term()}
  def unmoved(installed, name, opts) do
    with {:ok, again} <- Install.installed(name, opts) do
      if {again.revision, again.last} == {installed.revision, installed.last},
        do: :ok,
        else:
          {:error, :failed,
           "The Helm release of EHOS on #{name} changed while ehosctl waited: another command " <>
             "installed or upgraded it. ehosctl wrote nothing. Run this command again."}
    end
  end
end
