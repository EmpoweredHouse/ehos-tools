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
  `--host` keeps its address, unless `--host` gives another; one of sslip.io that names another
  address than the server's is refused, so `--host` must move it (eh-os D-124). So do the sign-in limits it was installed with (eh-os D-113), unless
  `--sign-in-absolute` or `--sign-in-idle` give others, checked as `install` checks them, whether
  its promotions need a second person (eh-os D-105), unless `--four-eyes` or `--no-four-eyes` say
  otherwise (ehos-tools#296), and the SMTP server it sends mail through (eh-os D-36), unless the
  `--smtp-*` options, `--mail-from` or `--no-mail` say otherwise. The registry credential is
  `GHCR_TOKEN`, and the SMTP user's password `SMTP_PASSWORD`, as for `install`.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.EhosRelease
  alias Ehosctl.GitHub
  alias Ehosctl.Install
  alias Ehosctl.Refusal

  # The most releases whose notes one run prints, as `ehosctl changelog` does; past them, a
  # release is weighed as one that migrates, unread.
  @max_printed 50
  # The most releases whose images are matched against the one an unrecorded EHOS runs.
  @max_scanned 100

  @impl Ehosctl.Command
  def name, do: :upgrade

  @impl Ehosctl.Command
  def plane, do: :platform

  @impl Ehosctl.Command
  def spec do
    [
      about:
        "Move EHOS on the server of an installation to another release, through the tunnel to " <>
          "the server. ehosctl shows the release notes first. Needs GHCR_TOKEN, and " <>
          "SMTP_PASSWORD for a user of an SMTP server.",
      options:
        [
          installation: [
            long: "--installation",
            value_name: "NAME",
            help:
              "The installation of the server. By default EHOSCTL_INSTALLATION, else the current " <>
                "installation, else trial."
          ],
          to: [
            long: "--to",
            value_name: "V",
            help: "The release of EHOS to move to. By default the newest release."
          ],
          host: [
            long: "--host",
            value_name: "HOST",
            help:
              "The host of the console. By default the host that EHOS serves now. The address " <>
                "of each application follows it."
          ]
        ] ++
          Install.sign_in_options() ++
          Install.mail_options() ++ Install.switch_options() ++ Install.allowed_domains_options(),
      flags:
        [
          allow_downgrade: [
            long: "--allow-downgrade",
            help:
              "Also move to a lower version. Migrations do not run backwards: the older code " <>
                "meets the database that the newer code left."
          ],
          allow_unrecorded: [
            long: "--allow-unrecorded",
            help:
              "Move an EHOS whose version nobody recorded and whose image matches no release, " <>
                "as `mix ehos.install` can leave it."
          ],
          yes: [long: "--yes", help: "Do not ask for confirmation."]
        ] ++
          Install.four_eyes_flags() ++
          Install.mail_flags() ++ Install.switch_flags() ++ Install.allowed_domains_flags()
    ]
  end

  @doc """
  Upgrades. `opts` as `Ehosctl.Install.call/3`'s. The question is asked of `Ehosctl.Terminal`.
  """
  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], parsed, opts) do
    with {:ok, name} <- Ehosctl.Server.installation(parsed.options[:installation], opts),
         {:ok, installed} <- Install.installed(name, opts),
         :ok <- Install.settled(installed, name, opts),
         :ok <- something_runs(installed, name),
         {:ok, releases} <- GitHub.releases("ehos", opts),
         {:ok, target} <- EhosRelease.chosen(releases, parsed.options[:to]),
         {:ok, described} <- GitHub.release_json(target, opts),
         {:ok, wanted} <- EhosRelease.installable(target, described),
         {:ok, from} <- running(installed, releases, opts),
         :ok <-
           Install.host_kept(parsed.options[:host], installed.host, name, opts, &"give #{&1}"),
         {:ok, sign_in} <- Install.sign_in(parsed, installed.sign_in, wanted["version"]),
         {:ok, four_eyes} <-
           Install.four_eyes(parsed, installed.four_eyes, wanted["version"]),
         {:ok, mail} <- Install.mail(parsed, installed.mail),
         # eh-os D-155: kept, as Helm would otherwise empty the list, unless the options give
         # another (ehos-tools#902).
         {:ok, allowed_domains} <-
           Install.allowed_domains(parsed, installed.allowed_domains, wanted["version"]),
         {:ok, move} <- move(from, wanted, parsed, name),
         # Nothing moves on the version that runs: its answer names the install that would ask.
         :ok <-
           if(move == :none,
             do: :ok,
             else:
               Install.password_given(
                 mail,
                 installed.mail,
                 Ehosctl.SystemEnv.current().all(),
                 parsed.flags[:no_mail] == true
               )
           ) do
      opts =
        opts
        |> Keyword.put(:sign_in, sign_in)
        |> Keyword.put(:four_eyes, four_eyes)
        |> Keyword.put(:mail, mail)
        |> Keyword.put(:allowed_domains, allowed_domains)
        |> Keyword.merge(Install.switch(parsed))

      upgrade(move, from, {target, described, wanted}, releases, installed, name, parsed, opts)
    end
  end

  # The sign-in limits, four eyes, SMTP settings and allowed domains given are named in the
  # command that installs them, rather than dropped.
  defp upgrade(:none, from, _target, _releases, _installed, name, parsed, _opts) do
    limits =
      parsed
      |> Install.given_sign_in()
      |> Enum.sort()
      |> Enum.map_join(fn {key, value} -> " --sign-in-#{key} #{value}" end)

    four_eyes =
      case Install.given_four_eyes(parsed) do
        nil -> ""
        given -> " " <> Install.four_eyes_argument(given)
      end

    mail = Install.mail_arguments(Install.given_mail(parsed))
    mail = if parsed.flags[:no_mail], do: mail <> " --no-mail", else: mail

    domains = domain_arguments(parsed)

    not_applied =
      for {given, what} <- [
            {limits, "the sign-in limits"},
            {four_eyes, "the four-eyes setting"},
            {mail, "the mail settings"},
            {domains, "the allowed domains"}
          ],
          given != "",
          do: what

    applied = if not_applied == [], do: "", else: " It did not apply #{and_list(not_applied)}."

    host =
      if parsed.options[:host],
        do: " --host #{EhosPlatform.Shell.word(parsed.options[:host])}",
        else: ""

    options = host <> limits <> four_eyes <> mail <> domains

    applied =
      if Ehosctl.SystemEnv.current().all()["SMTP_PASSWORD"] in [nil, ""],
        do: applied,
        else: applied <> " It did not write SMTP_PASSWORD."

    {:ok,
     %{
       text:
         "#{name} runs EHOS #{from.version} already. ehosctl changed nothing.#{applied} To " <>
           "install it again, run `ehosctl install --installation #{name} --version " <>
           "#{from.version}#{options}`.",
       json: nil
     }}
  end

  defp upgrade(move, from, {target, described, wanted}, releases, installed, name, parsed, opts) do
    on_the_way = on_the_way(move, from, wanted, releases)
    read = read(on_the_way, {target, described}, opts)

    IO.puts(
      heading(move, from, wanted, name) <>
        "\n" <>
        where(parsed.options[:host] || installed.host) <>
        signs_in(Keyword.get(opts, :sign_in)) <>
        approves(Keyword.get(opts, :four_eyes), installed, wanted["version"]) <>
        mails(Keyword.get(opts, :mail)) <>
        allows(Keyword.get(opts, :allowed_domains), installed.allowed_domains)
    )

    if read != [], do: IO.puts(notes(read))
    # Before the question, so it is answered knowing.
    Install.warn_relay(Keyword.get(opts, :mail))

    case confirmed(question(move, from, wanted, read), parsed) do
      :ok ->
        with {:ok, done} <-
               Install.install(name, wanted, parsed.options[:host] || installed.host, opts),
             do: {:ok, %{done | text: Install.failed_before(installed) <> done.text}}

      :not_confirmed ->
        {:ok, %{text: "ehosctl changed nothing.", json: nil}}
    end
  end

  # Said before GitHub is asked anything, so it is said offline too.
  defp something_runs(%{running: :none}, name),
    do:
      {:error, :invalid,
       "#{name} runs no EHOS to upgrade. To install EHOS, run " <>
         "`ehosctl install --installation #{name}`."}

  defp something_runs(_installed, _name), do: :ok

  # What runs, as a version and how it is known: recorded by `install` (`:as`, what it recorded),
  # or found by the digest of the image an EHOS that recorded nothing runs; else `nil`, with why,
  # which only --allow-unrecorded moves.
  defp running(%{running: %{"version" => version} = recorded} = installed, releases, opts) do
    case Version.parse(version) do
      {:ok, _version} -> {:ok, %{version: version, recorded?: true, as: recorded}}
      :error -> running(%{installed | running: :unknown}, releases, opts)
    end
  end

  defp running(%{running: :unknown, digest: nil}, _releases, _opts),
    do: {:ok, %{version: nil, recorded?: false, why: :no_digest}}

  defp running(%{running: :unknown, digest: digest}, releases, opts) do
    # Newest first, stopping at the first release whose image it is: the stream is lazy.
    scanned =
      releases
      |> Enum.take(@max_scanned)
      |> Task.async_stream(&{&1, GitHub.release_json(&1, opts)},
        timeout: :infinity,
        max_concurrency: 4
      )
      |> Enum.reduce_while([], fn {:ok, {release, json}}, unread ->
        scan_step(json, release, unread, digest)
      end)

    case scanned do
      {:matched, release} ->
        {:ok, %{version: release.version, recorded?: false}}

      [] ->
        {:ok,
         %{
           version: nil,
           recorded?: false,
           why: if(length(releases) > @max_scanned, do: :not_among_newest, else: :no_match)
         }}

      unread ->
        {release, message} = List.last(unread)
        {:ok, %{version: nil, recorded?: false, why: {:unread, release, message}}}
    end
  end

  defp scan_step({:ok, described}, release, unread, digest) do
    if EhosRelease.image_digest(described) == digest,
      do: {:halt, {:matched, release}},
      else: {:cont, unread}
  end

  defp scan_step({:error, _kind, message}, release, unread, _digest),
    do: {:cont, [{release, message} | unread]}

  # Which way it goes: :up, :down, :none, or :unrecorded, each refused as the flags say.
  defp move(%{version: nil, why: why}, wanted, parsed, name) do
    if parsed.flags.allow_unrecorded,
      do: {:ok, :unrecorded},
      else:
        {:error, :invalid,
         "#{name} runs an EHOS whose version nobody recorded, and #{unmatched(why)}. So " <>
           "ehosctl cannot tell if #{wanted["version"]} is newer: the EHOS that runs can be a " <>
           "build of a later commit. Give --allow-unrecorded to move it to " <>
           "#{wanted["version"]} anyway. ehosctl changed nothing."}
  end

  defp move(%{version: from, recorded?: recorded?} = running, wanted, parsed, name) do
    case Version.compare(wanted["version"], from) do
      :gt ->
        {:ok, :up}

      # An EHOS that recorded nothing is installed from its own release, which records it.
      :eq when not recorded? ->
        {:ok, :up}

      :eq ->
        if Map.take(running.as, ["image", "chart"]) == Map.take(wanted, ["image", "chart"]),
          do: {:ok, :none},
          else:
            {:error, :failed,
             "#{name} runs EHOS #{from} as #{Refusal.shown(running.as["image"])}, from " <>
               "#{Refusal.shown(running.as["chart"])}, but its release now names " <>
               "#{wanted["image"]}, from #{wanted["chart"]}. Nobody changes a release after it " <>
               "is published. Find out who changed it before you install anything from it. " <>
               "ehosctl changed nothing."}

      :lt ->
        if parsed.flags.allow_downgrade,
          do: {:ok, :down},
          else:
            {:error, :invalid,
             "#{name} runs EHOS #{from}, and #{wanted["version"]} is older. Migrations do not " <>
               "run backwards, so the code of #{wanted["version"]} meets the database that " <>
               "#{from} left. Give --allow-downgrade to move down anyway. ehosctl changed nothing."}
    end
  end

  defp unmatched({:unread, release, message}),
    do:
      "ehosctl could not read each release to find the release of its image " <>
        "(#{release.tag}: #{message})"

  defp unmatched(:no_digest), do: "ehosctl could not read the digest of its image"
  defp unmatched(:no_match), do: "its image is in no release"

  defp unmatched(:not_among_newest),
    do: "its image is in none of the newest #{@max_scanned} releases"

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

  # Each release's `release.json` and notes, newest first, for the first @max_printed: one
  # further on is `:left_out`, read for neither, and weighed as one that migrates. The target's
  # `release.json` is the one already read.
  defp read(releases, {target, described}, opts) do
    {read, left_out} = Enum.split(releases, @max_printed)

    read =
      read
      |> Task.async_stream(
        fn release ->
          json =
            if release.tag == target.tag,
              do: {:ok, described},
              else: GitHub.release_json(release, opts)

          {release, json, GitHub.notes(release, opts)}
        end,
        timeout: :infinity,
        max_concurrency: 4
      )
      |> Enum.map(fn {:ok, read} -> read end)

    read ++ for(release <- left_out, do: {release, :left_out, nil})
  end

  # Where the console will be: where it is now, as the running revision serves it.
  defp where(nil),
    do:
      "ehosctl could not read the address of the console from the cluster. The console will " <>
        "be at ehos.<address>.sslip.io, from the address of the tunnel."

  defp where(host), do: "The console stays at https://#{host}."

  # eh-os D-113: the limits it will run with, when they are not the chart's.
  defp signs_in(nil), do: ""

  defp signs_in(limits),
    do:
      " A sign-in to an application lasts #{Map.get(limits, "absolute", "12h")}, and " <>
        "#{Map.get(limits, "idle", "1h")} when the person does not use it."

  # eh-os D-105: said when four eyes is off, by a value given or, left to a chart that keeps what
  # runs (D-128), as the server runs (ehos-tools#350).
  defp approves(false, _installed, _version), do: without_second_person()

  defp approves(nil, %{four_eyes_runs: false}, version) do
    if Install.four_eyes_kept?(version), do: without_second_person(), else: ""
  end

  defp approves(_on, _installed, _version), do: ""

  defp without_second_person,
    do:
      " The person who deployed or asked for a promotion can approve it, without a second " <>
        "person."

  defp and_list([only]), do: only
  defp and_list([first, second]), do: "#{first} and #{second}"
  defp and_list([first | rest]), do: "#{first}, #{and_list(rest)}"

  defp domain_arguments(parsed) do
    given =
      Enum.map_join(
        parsed.options[:allowed_domain] || [],
        &" --allowed-domain #{EhosPlatform.Shell.word(&1)}"
      )

    given <> no_domains(parsed.flags[:no_allowed_domains])
  end

  defp no_domains(true), do: " --no-allowed-domains"
  defp no_domains(_not_given), do: ""

  # Said when the options change the list, which they replace as a whole (ehos-tools#902).
  defp allows(same, same), do: ""
  defp allows(nil, _running), do: ""
  defp allows([], _running), do: " A person can map no domain of your company: EHOS allows none."

  defp allows(domains, _running),
    do:
      " A person can map #{and_list(Enum.map(domains, &Refusal.shown/1))}, or a name under " <>
        "them, and no other domain."

  defp mails(nil), do: " EHOS sends no mail."

  defp mails(%{"from" => from, "smtp" => smtp}),
    do:
      " EHOS sends mail from #{Refusal.shown(from)} through " <>
        "#{Refusal.shown(smtp["host"])}:#{smtp["port"]}" <>
        if(smtp["username"], do: " as #{Refusal.shown(smtp["username"])}.", else: ".")

  defp heading(:up, %{version: same, recorded?: false}, %{"version" => same}, name),
    do:
      "#{name} runs EHOS #{same}, by the digest of its image, but nothing recorded its " <>
        "version. ehosctl installs it again from its release, which records the version."

  defp heading(:up, %{version: from, recorded?: recorded?}, wanted, name),
    do:
      "#{name} runs EHOS #{from}#{if recorded?, do: "", else: ", by the digest of its image"}. " <>
        "ehosctl moves it to #{wanted["version"]}."

  defp heading(:down, %{version: from}, wanted, name),
    do: "#{name} runs EHOS #{from}. ehosctl moves it down to #{wanted["version"]}."

  defp heading(:unrecorded, _from, wanted, name),
    do:
      "#{name} runs an EHOS whose version nobody recorded. ehosctl moves it to " <>
        "#{wanted["version"]}."

  defp notes(read) do
    printed = for {release, _described, notes} <- read, notes != nil, do: {release, notes}

    left_out =
      case length(read) - length(printed) do
        0 -> ""
        1 -> "\n\nehosctl leaves out 1 older release"
        n -> "\n\nehosctl leaves out #{n} older releases"
      end

    "\n" <>
      Ehosctl.ReleaseNotes.printed("ehos", printed) <>
      if left_out == "",
        do: "",
        else:
          left_out <>
            ". The notes are at https://github.com/#{GitHub.repository("ehos")}/releases."
  end

  # The question before a change that cannot be taken back, or nil when there is none: the
  # database is changed, or may be, and EHOS keeps no backup of it (eh-os#249).
  defp question(:down, %{version: from}, wanted, _read),
    do:
      "EHOS #{wanted["version"]} will run on the governance database as #{from} left it, and " <>
        "possibly cannot read it. EHOS keeps no backup of the database. Move down to " <>
        "#{wanted["version"]}?"

  defp question(:unrecorded, _from, wanted, _read),
    do:
      "The move to #{wanted["version"]} can change the governance database, and EHOS keeps no " <>
        "backup of it. Continue?"

  defp question(:up, _from, wanted, read) do
    migrating =
      for {release, {:ok, described}, _notes} <- read,
          not match?(%{"migrates" => false}, described),
          do: release.version

    unread = for {release, {:error, _kind, _message}, _notes} <- read, do: release.version
    left_out = Enum.count(read, &match?({_release, :left_out, _notes}, &1))

    case migrations_said(migrating, unread, left_out) do
      [] ->
        nil

      [first | rest] ->
        Enum.map_join([first | rest], "", &(&1 <> ". ")) <>
          "EHOS keeps no backup of that database: after a change, you cannot go back. Move to " <>
          "#{wanted["version"]}?"
    end
  end

  defp migrations_said(migrating, unread, left_out) do
    Enum.reject(
      [
        migrating != [] &&
          "EHOS #{Enum.join(Enum.reverse(migrating), ", ")} changes the governance " <>
            "database, or does not say if it does",
        unread != [] &&
          "ehosctl could not read the release.json of EHOS " <>
            "#{Enum.join(Enum.reverse(unread), ", ")} to see if it changes the governance " <>
            "database",
        left_out > 0 &&
          "ehosctl did not read #{left_out} older release#{if left_out > 1, do: "s"} on the " <>
            "way, which can change the governance database"
      ],
      &(&1 == false)
    )
  end

  defp confirmed(nil, _parsed), do: :ok

  defp confirmed(question, parsed) do
    if parsed.flags.yes or Ehosctl.Terminal.confirm(question),
      do: :ok,
      else: :not_confirmed
  end
end
