defmodule Ehosctl.Upgrade do
  @moduledoc """
  `ehosctl upgrade`: moves the EHOS on an installation's server to another release, by version
  (eh-os D-79, D-92), through the same install as `ehosctl install` (`Ehosctl.Install.install/4`).

  What runs is read from the cluster, as `install` reads it: the Helm release's last deployed
  revision, never EHOS's API. The target is `--to`, the newest release by default. Before
  anything changes, `upgrade` prints the notes of every release after the one that runs, up to
  the target, as `ehosctl changelog` prints them, and:

    * refuses a lower version unless `--allow-downgrade`, since migrations do not run backwards;
    * changes nothing for the version that runs, which `install` installs again;
    * asks first when a release on the way changes the governance database (`migrates` in its
      `release.json`, or none said), since EHOS keeps no backup of it (eh-os#249), and before any
      downgrade; `--yes` answers, and with no answer nothing changes.

  An EHOS that `mix ehos.install` installed recorded no version. Its image's digest is matched
  against the releases' images: one that matches runs that release. One that matches none cannot
  be told from a newer build, so it is moved only with `--allow-unrecorded`, after the question,
  and its version is recorded from then on (eh-os#422).

  The console's host stays the one the running revision serves, so an installation made with
  `--host` keeps its address. The registry credential is `GHCR_TOKEN`, as for `install`.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.EhosRelease
  alias Ehosctl.GitHub
  alias Ehosctl.Install

  # The most releases whose notes one run prints, as `ehosctl changelog` does.
  @max_printed 50

  @impl Ehosctl.Command
  def name, do: :upgrade

  @impl Ehosctl.Command
  def plane, do: :platform

  @impl Ehosctl.Command
  def spec do
    [
      about:
        "Move EHOS on the server under an installation to another release, after its notes, " <>
          "through its tunnel, with your kubeconfig and GHCR_TOKEN.",
      options: [
        installation: [
          long: "--installation",
          value_name: "NAME",
          help:
            "The installation whose server this is, instead of EHOSCTL_INSTALLATION, the " <>
              "current one, or trial."
        ],
        to: [
          long: "--to",
          value_name: "V",
          help: "The EHOS release to move to; the newest by default."
        ]
      ],
      flags: [
        allow_downgrade: [
          long: "--allow-downgrade",
          help:
            "Move to a lower version too. Migrations do not run backwards: the older code meets " <>
              "the database the newer one left."
        ],
        allow_unrecorded: [
          long: "--allow-unrecorded",
          help:
            "Move an EHOS whose version nothing recorded and no release's image matches, as " <>
              "`mix ehos.install` may leave it."
        ],
        yes: [long: "--yes", help: "Do not ask."]
      ]
    ]
  end

  @doc """
  Upgrades. `opts` as `Ehosctl.Install.call/3`'s, and `:confirm` (asks a question, returns
  whether the answer was yes) and `:print` (prints a line to the person before the question).
  """
  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], parsed, opts) do
    with {:ok, name} <- Ehosctl.Server.installation(parsed.options[:installation], opts),
         {:ok, installed} <- Install.installed(name, opts),
         :ok <- Install.settled(installed, name),
         {:ok, releases} <- GitHub.releases("ehos", opts),
         {:ok, target} <- EhosRelease.chosen(releases, parsed.options[:to]),
         {:ok, described} <- GitHub.release_json(target, opts),
         {:ok, wanted} <- EhosRelease.installable(target, described),
         {:ok, from} <- running(installed, releases, name, opts),
         {:ok, move} <- move(from, wanted, parsed, name) do
      upgrade(move, from, wanted, releases, installed, name, parsed, opts)
    end
  end

  defp upgrade(:none, from, _wanted, _releases, _installed, name, _parsed, _opts) do
    {:ok,
     %{
       text:
         "#{name} runs EHOS #{from.version} already. Nothing was changed; `ehosctl install " <>
           "--installation #{name} --version #{from.version}` installs it again.",
       json: nil
     }}
  end

  defp upgrade(move, from, wanted, releases, installed, name, parsed, opts) do
    print = Keyword.get(opts, :print, &IO.puts/1)
    on_the_way = on_the_way(move, from, wanted, releases)
    read = read(on_the_way, opts)

    print.(heading(move, from, wanted, name))
    print.(notes(read, on_the_way))

    case confirmed(question(move, from, wanted, read), parsed, opts) do
      :ok ->
        with {:ok, done} <- Install.install(name, wanted, installed.host, opts),
             do: {:ok, %{done | text: Install.failed_before(installed) <> done.text}}

      :not_confirmed ->
        {:ok, %{text: "Nothing was changed.", json: nil}}
    end
  end

  # What runs, as a version and how it is known: recorded by `install`, or found by the digest of
  # the image an EHOS that recorded nothing runs; else `nil`, which only --allow-unrecorded moves.
  defp running(%{running: :none}, _releases, name, _opts),
    do:
      {:error, :invalid,
       "#{name} runs no EHOS to upgrade: `ehosctl install --installation #{name}` installs it."}

  defp running(%{running: %{"version" => version}} = installed, releases, name, opts) do
    case Version.parse(version) do
      {:ok, _version} -> {:ok, %{version: version, recorded?: true}}
      :error -> running(%{installed | running: :unknown}, releases, name, opts)
    end
  end

  defp running(%{running: :unknown, digest: digest}, releases, _name, opts) do
    matched =
      digest &&
        releases
        |> Task.async_stream(&{&1, GitHub.release_json(&1, opts)},
          timeout: :infinity,
          max_concurrency: 4
        )
        |> Enum.find_value(fn
          {:ok, {release, {:ok, described}}} ->
            if EhosRelease.image_digest(described) == digest, do: release

          _unread ->
            nil
        end)

    case matched do
      nil -> {:ok, %{version: nil, recorded?: false}}
      release -> {:ok, %{version: release.version, recorded?: false}}
    end
  end

  # Which way it goes: :up, :down, :none, or :unrecorded, each refused as the flags say.
  defp move(%{version: nil}, wanted, parsed, name) do
    if parsed.flags.allow_unrecorded,
      do: {:ok, :unrecorded},
      else:
        {:error, :invalid,
         "#{name} runs an EHOS whose version nothing recorded, and its image is no release's, " <>
           "so ehosctl cannot tell whether #{wanted["version"]} is newer: it may be a build " <>
           "of a later commit. Give --allow-unrecorded to move it to #{wanted["version"]} " <>
           "anyway. Nothing was changed."}
  end

  defp move(%{version: from, recorded?: recorded?}, wanted, parsed, name) do
    case Version.compare(wanted["version"], from) do
      :gt ->
        {:ok, :up}

      :eq ->
        # An EHOS that recorded nothing is installed from its own release, which records it.
        if recorded?, do: {:ok, :none}, else: {:ok, :up}

      :lt ->
        if parsed.flags.allow_downgrade,
          do: {:ok, :down},
          else:
            {:error, :invalid,
             "#{name} runs EHOS #{from}, and #{wanted["version"]} is older. Migrations do not " <>
               "run backwards, so its code would meet the database #{from} left. Give " <>
               "--allow-downgrade to go down anyway. Nothing was changed."}
    end
  end

  # The releases whose notes are printed and whose migrations are weighed, newest first: those
  # after the one that runs up to the target; going down, those whose migrations stay behind.
  defp on_the_way(:unrecorded, _from, wanted, releases),
    do: Enum.filter(releases, &(&1.version == wanted["version"]))

  defp on_the_way(:up, %{version: from}, wanted, releases),
    do: Enum.filter(releases, &between?(&1.version, from, wanted["version"]))

  defp on_the_way(:down, %{version: from}, wanted, releases),
    do: Enum.filter(releases, &between?(&1.version, wanted["version"], from))

  defp between?(version, low, high),
    do: Version.compare(version, low) == :gt and Version.compare(version, high) != :gt

  # Each release's `release.json` and notes, newest first, the notes of the first @max_printed.
  defp read(releases, opts) do
    releases
    |> Enum.with_index()
    |> Task.async_stream(
      fn {release, index} ->
        notes = if index < @max_printed, do: GitHub.notes(release, opts)
        {release, GitHub.release_json(release, opts), notes}
      end,
      timeout: :infinity,
      max_concurrency: 4
    )
    |> Enum.map(fn {:ok, read} -> read end)
  end

  defp heading(:up, %{version: same, recorded?: false}, %{"version" => same}, name),
    do:
      "#{name} runs EHOS #{same}, by its image's digest, but recorded nothing; installing it " <>
        "again from its release records it."

  defp heading(:up, %{version: from, recorded?: recorded?}, wanted, name),
    do:
      "#{name} runs EHOS #{from}#{if recorded?, do: "", else: ", by its image's digest"}; " <>
        "moving it to #{wanted["version"]}."

  defp heading(:down, %{version: from}, wanted, name),
    do: "#{name} runs EHOS #{from}; moving it down to #{wanted["version"]}."

  defp heading(:unrecorded, _from, wanted, name),
    do: "#{name} runs an EHOS whose version nothing recorded; moving it to #{wanted["version"]}."

  defp notes(read, on_the_way) do
    printed =
      for {release, _described, notes} <- read, notes != nil, do: {release, notes}

    left_out = length(on_the_way) - length(printed)

    "\n" <>
      Ehosctl.ReleaseNotes.printed("ehos", printed) <>
      if left_out > 0,
        do:
          "\n\n#{left_out} older releases are left out: their notes are at " <>
            "https://github.com/#{GitHub.repository("ehos")}/releases.",
        else: ""
  end

  # The question before a change that cannot be taken back, or nil when there is none: the
  # database is changed, or may be, and EHOS keeps no backup of it (eh-os#249).
  defp question(:down, %{version: from}, wanted, _read),
    do:
      "EHOS #{wanted["version"]} will run on the governance database as #{from} left it, which " <>
        "it may not read, and EHOS keeps no backup of it to go back to. Move down to " <>
        "#{wanted["version"]}?"

  defp question(:unrecorded, _from, wanted, _read),
    do:
      "Moving to #{wanted["version"]} may change the governance database, and EHOS keeps no " <>
        "backup of it to go back to. Go on?"

  defp question(:up, _from, wanted, read) do
    migrating =
      for {release, described, _notes} <- read,
          not match?({:ok, %{"migrates" => false}}, described),
          do: release.version

    case migrating do
      [] ->
        nil

      versions ->
        "EHOS #{Enum.join(Enum.reverse(versions), ", ")} changes the governance database, or " <>
          "does not say, and EHOS keeps no backup of it: once changed, it cannot go back. " <>
          "Move to #{wanted["version"]}?"
    end
  end

  defp confirmed(nil, _parsed, _opts), do: :ok

  defp confirmed(question, parsed, opts) do
    confirm = Keyword.get(opts, :confirm, &confirm/1)

    if parsed.flags.yes or confirm.(question),
      do: :ok,
      else: :not_confirmed
  end

  # A question with no answer, as a script's stdin gives, is a no.
  defp confirm(question) do
    case IO.gets(:stdio, question <> " [y/N] ") do
      answer when is_binary(answer) -> String.downcase(String.trim(answer)) in ["y", "yes"]
      _eof -> false
    end
  end
end
