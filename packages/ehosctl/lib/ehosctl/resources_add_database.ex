defmodule Ehosctl.ResourcesAddDatabase do
  @moduledoc """
  `ehosctl resources add-database NAME`: lists a PostgreSQL database outside the installation,
  such as one on Cloud SQL or RDS, as a resource that environments can bind (eh-os D-170, T-29).
  It runs under `ehosctl resources` (`c:Ehosctl.Command.mounted/0`), on the platform plane:
  through the kubeconfig `ehosctl server tunnel` wrote, never through EHOS's API.

  The list lives in the Helm release alone, as the other settings `install` and `upgrade` keep.
  The command runs in this order, and writes nothing before step 6:

    1. It checks each field as the chart does (`EhosPlatform.ExternalDatabases.check/1`), and
       reads the managing role's password from `--password-file`: a file, or `-`, standard input
       from a pipe or a file, never a terminal (`Ehosctl.SecretInput`). The password is never an
       argument. With `-`, standard input is the pipe, so it cannot ask, and needs `--yes`.
    2. It reads what runs (`Ehosctl.Install.installed/2`), and refuses when nothing runs, when
       the EHOS that runs is before `Ehosctl.Install.external_since/0`, or when it lists the name
       already: changing or
       removing an entry is not this command's.
    3. It reads the release of the version that runs from GitHub (`Ehosctl.EhosRelease`), and
       refuses, as `install` does, when what runs is not that published release's image and chart.
    4. It renders the chart that runs with the list and the new entry
       (`EhosPlatform.Install.render_running/1`), so the chart's own refusals come first, and
       prints what it adds, without the password. The render uses the release's own values: a
       refusal that only the values the install rebuilds cause shows at step 7, after the Secret
       is written, and a run again replaces that Secret.
    5. It asks before it writes, unless `--yes`, and reads the release's deployed revision again:
       one that moved since step 2, as when another command installed, is refused.
    6. It writes the managing role into the Secret `ehos-external-<name>` in `ehos-data`
       (`EhosPlatform.Install.write_external_secret/4`), which it makes, or replaces when it made
       it before for the same database.
    7. It installs the version that runs again, as `upgrade` does (`Ehosctl.Install.install/4`),
       with every other setting kept from what runs (`Ehosctl.Install.kept/3`).
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.EhosRelease
  alias Ehosctl.Install
  alias Ehosctl.Output
  alias Ehosctl.Refusal
  alias Ehosctl.SecretInput
  alias EhosPlatform.ExternalDatabases

  # The most bytes of a password that is read; PostgreSQL takes far fewer.
  @max_password 4_096
  # The most bytes of the CA's file that is read.
  @max_ca 1_048_576

  @impl Ehosctl.Command
  def name, do: :"add-database"

  @impl Ehosctl.Command
  def plane, do: :platform

  @impl Ehosctl.Command
  def group, do: :installation

  @impl Ehosctl.Command
  def summary, do: "Add a database outside the installation as a resource."

  @impl Ehosctl.Command
  def spec do
    [
      about:
        "Add a PostgreSQL database outside the installation, such as one on Cloud SQL or RDS, " <>
          "as a resource that environments can bind. ehosctl shows what it adds, writes the " <>
          "managing role into a Secret on the server, and installs the version of EHOS that " <>
          "runs again from its release, through the tunnel to the server. Needs GHCR_TOKEN. " <>
          "For developing EHOS only: the chart takes the database only with " <>
          "dataResources.externalUnderDevelopment.",
      args: [
        name: [
          value_name: "NAME",
          required: true,
          help:
            "The name of the resource. Format: lowercase letters, digits and -, starting with " <>
              "a letter, at most 50 characters."
        ]
      ],
      options: [
        installation: [
          long: "--installation",
          value_name: "NAME",
          help:
            "The installation of the server. By default EHOSCTL_INSTALLATION, else the current " <>
              "installation, else trial."
        ],
        host: [
          long: "--host",
          value_name: "HOST",
          required: true,
          help:
            "The DNS name of the database server, which its certificate carries. Give a name " <>
              "that you control. Format: lowercase, such as db.example.com, not an address."
        ],
        port: [
          long: "--port",
          value_name: "PORT",
          parser: :integer,
          default: 5432,
          help: "The port of the database server."
        ],
        database: [
          long: "--database",
          value_name: "DATABASE",
          required: true,
          help: "The database on the server that EHOS gets. Format: a lowercase PostgreSQL name."
        ],
        version: [
          long: "--version",
          value_name: "MAJOR",
          parser: :integer,
          required: true,
          help: "The major version of PostgreSQL on the server, 16 or later, such as 17."
        ],
        ca_file: [
          long: "--ca-file",
          value_name: "PATH",
          required: true,
          help: "A file with the certificates, in PEM, that signed the certificate of the server."
        ],
        address_range: [
          long: "--address-range",
          value_name: "CIDR",
          multiple: true,
          required: true,
          help:
            "An IPv4 range that the database answers from, such as 10.20.0.0/24. Give it once " <>
              "for each range. Each is /20 or narrower."
        ],
        username: [
          long: "--username",
          value_name: "ROLE",
          required: true,
          help: "The managing role that EHOS signs in as. It must not be a superuser."
        ],
        administrator_role: [
          long: "--administrator-role",
          value_name: "ROLE",
          help:
            "Your own role on the server. EHOS lets it grant the groups of each schema. " <>
              "Optional."
        ],
        password_file: [
          long: "--password-file",
          value_name: "PATH",
          required: true,
          help:
            "A file that holds the password of the managing role, or - to read it from " <>
              "standard input, from a pipe or a file. ehosctl never reads it from a terminal. " <>
              "With -, give --yes too."
        ]
      ],
      flags: [yes: [long: "--yes", help: "Do not ask for confirmation."]]
    ]
  end

  @doc """
  Adds the database. `opts` as `Ehosctl.Install.call/3`'s: `:install` is the module that does the
  platform's work, `EhosPlatform.Install` by default.
  """
  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], parsed, opts) do
    with {:ok, name} <- Ehosctl.Server.installation(parsed.options[:installation], opts),
         :ok <- answerable(parsed),
         {:ok, ca} <- ca(parsed.options.ca_file),
         entry = entry(parsed, ca),
         :ok <- checked(entry),
         :ok <- username_checked(parsed.options.username),
         {:ok, password} <- password(parsed.options.password_file, entry["name"]),
         {:ok, installed} <- Install.installed(name, opts),
         :ok <- Install.settled(installed, name, opts),
         {:ok, version} <- running_version(installed.running, name),
         :ok <- not_listed(installed.external_databases, entry["name"], name),
         {:ok, release, described} <- EhosRelease.find(version, opts),
         {:ok, wanted} <- EhosRelease.installable(release, described),
         :ok <- Install.may_install(installed.running, wanted, name),
         :ok <- Install.host_kept(nil, installed.host, name, opts, &upgrade_first(name, &1)),
         :ok <- readable_mail(installed.mail, name),
         listed = (installed.external_databases || []) ++ [entry],
         {:ok, kept} <-
           Install.kept(parsed, %{installed | external_databases: listed}, version),
         env = Ehosctl.SystemEnv.current().all(),
         # The mail is kept as it runs, so no refusal names an SMTP option it does not take, and
         # a stray SMTP_PASSWORD is neither refused nor written.
         :ok <- Install.password_given(kept[:mail], installed.mail, env, true),
         :ok <- rendered(name, listed, installed, env, opts),
         :ok <- previewed(entry, name, wanted, installed, kept[:mail]),
         :ok <- asked(entry, name, version, parsed),
         :ok <- unmoved(installed, name, opts),
         {:ok, written} <-
           secret_written(name, entry, {parsed.options.username, password}, opts),
         {:ok, done} <-
           Install.install(
             name,
             wanted,
             installed.host,
             opts |> Keyword.merge(kept) |> Keyword.put(:keep_smtp_password, true)
           ) do
      Install.warn_failed_before(installed)

      secret = %EhosPlatform.Secret{
        kind: :external_database_role,
        place: "#{ExternalDatabases.namespace()}/#{entry["managingRoleSecret"]}",
        read_from: read_from(parsed.options.password_file)
      }

      added = added(entry["name"], name, written, secret)
      {:ok, %{done | text: Output.lines([added, "", done.text])}}
    end
  end

  # With `--password-file -`, standard input is the pipe that holds the password, so nobody can
  # answer the question there.
  defp answerable(%{options: %{password_file: "-"}, flags: flags}) do
    if flags[:yes] == true,
      do: :ok,
      else:
        {:error, :invalid,
         "With --password-file -, standard input holds the password, so ehosctl cannot ask " <>
           "before it writes. Give --yes to write without a question, or give the password in " <>
           "a file. ehosctl changed nothing."}
  end

  # Any other standard input that is not a terminal cannot answer either: a pipe read as
  # `--password-file /dev/stdin` is empty by the time the question comes.
  defp answerable(%{flags: flags}) do
    if flags[:yes] == true or Ehosctl.Terminal.current().input_terminal?(),
      do: :ok,
      else:
        {:error, :invalid,
         "Standard input is not a terminal, so ehosctl cannot ask before it writes. Give --yes " <>
           "to write without a question. ehosctl changed nothing."}
  end

  # After the preview and every warning, so the question is answered knowing.
  defp asked(entry, name, version, parsed) do
    question =
      "Write the Secret #{ExternalDatabases.namespace()}/#{entry["managingRoleSecret"]} and " <>
        "install EHOS #{version} on #{name} again?"

    case Install.confirmed(question, parsed) do
      :ok -> :ok
      :not_confirmed -> {:ok, %{text: "ehosctl changed nothing.", json: nil}}
    end
  end

  # Another command that installed or upgraded since `installed/1` read the release would have
  # its change lost under this install: a change before this second read is refused before
  # anything is written. One that starts between this read and the pending revision Helm makes is
  # not caught: Helm has no compare-and-set.
  defp unmoved(installed, name, opts) do
    with {:ok, again} <- Install.installed(name, opts) do
      if {again.revision, again.last} == {installed.revision, installed.last},
        do: :ok,
        else:
          {:error, :failed,
           "The Helm release of EHOS on #{name} changed while ehosctl waited: another command " <>
             "installed or upgraded it. ehosctl wrote nothing. Run this command again."}
    end
  end

  # What it adds, on stdout before anything is written, and each warning the install would give.
  defp previewed(entry, name, wanted, installed, mail) do
    Output.result(%{text: preview(entry, name, wanted), json: nil}, false)
    Install.warn_left_out(installed)
    Install.warn_relay(mail)
  end

  # The CA as the file holds it, bounded, so a device or a huge file is refused.
  defp ca(path) do
    texts = %{
      subject: "The file of --ca-file",
      of: "the CA",
      most: "the most that ehosctl reads",
      nothing: "ehosctl changed nothing.",
      give: "Give --ca-file with a file."
    }

    with {:ok, pem} <- SecretInput.read(path, @max_ca, texts) do
      if String.valid?(pem),
        do: {:ok, pem},
        else:
          {:error, :invalid,
           "The file of --ca-file is not text. Give the certificates in PEM. " <>
             "ehosctl changed nothing."}
    end
  end

  # The entry as the chart lists it, the Secret named by ehosctl and never by the person.
  defp entry(parsed, ca) do
    name = parsed.args.name

    %{
      "name" => name,
      "version" => parsed.options.version,
      "host" => parsed.options.host,
      "port" => parsed.options.port,
      "database" => parsed.options.database,
      "ca" => ca,
      "addressRanges" => parsed.options.address_range,
      "managingRoleSecret" => ExternalDatabases.secret_name(name)
    }
    |> maybe_put("administratorRole", parsed.options[:administrator_role])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp checked(entry) do
    case ExternalDatabases.check(entry) do
      :ok ->
        :ok

      {:error, field, rule} ->
        {:error, :invalid,
         "#{subject(field)} #{rule}#{refused_value(field, entry[field])}. ehosctl changed nothing."}
    end
  end

  # A role's name as PostgreSQL takes one, at most 63 bytes, and nothing a terminal acts on.
  defp username_checked(username) do
    if byte_size(username) in 1..63 and username =~ ~r/\A[!-~]+\z/,
      do: :ok,
      else:
        {:error, :invalid,
         "--username must be the name of a role, of at most 63 characters of printable ASCII " <>
           "without spaces, and #{Refusal.shown(username)} is not. ehosctl changed nothing."}
  end

  defp subject("name"), do: "NAME"
  defp subject("version"), do: "--version"
  defp subject("host"), do: "--host"
  defp subject("port"), do: "--port"
  defp subject("database"), do: "--database"
  defp subject("ca"), do: "The file of --ca-file"
  defp subject("addressRanges"), do: "Each --address-range"
  defp subject("managingRoleSecret"), do: "The Secret of the managing role"
  defp subject("administratorRole"), do: "--administrator-role"

  # The value refused, where the rule does not name it already.
  defp refused_value(field, _value) when field in ["ca", "addressRanges"], do: ""

  defp refused_value(_field, value) when is_binary(value),
    do: ", and #{Refusal.shown(value)} is not"

  defp refused_value(_field, value), do: ", and #{inspect(value)} is not"

  defp password(path, name) do
    texts = %{
      subject: "The password",
      of: "the password",
      most: "the most that ehosctl reads",
      nothing: "ehosctl changed nothing.",
      give:
        "Give --password-file with a file, or --password-file - with a pipe or a file, as " <>
          "in `ehosctl resources add-database #{Refusal.shown(name)} … --password-file - < " <>
          "password.txt`."
    }

    source = if path == "-", do: :stdin, else: path

    with {:ok, read} <- SecretInput.read(source, @max_password, texts) do
      password = SecretInput.chomp(read)

      cond do
        password == "" ->
          {:error, :invalid, "The password is empty. ehosctl changed nothing."}

        not String.valid?(password) or String.contains?(password, ["\n", "\r", <<0>>]) ->
          {:error, :invalid,
           "The password is not one line of UTF-8 text. ehosctl changed nothing."}

        true ->
          {:ok, password}
      end
    end
  end

  # The version that runs, which is installed again from its published release.
  defp running_version(:none, name),
    do:
      {:error, :invalid,
       "#{name} runs no EHOS, so it has no list of resources. Run `ehosctl install " <>
         "--installation #{name}` first. ehosctl changed nothing."}

  defp running_version(%{"version" => version}, name) do
    if Install.external_databases?(version),
      do: {:ok, version},
      else:
        {:error, :invalid,
         "#{name} runs EHOS #{Refusal.shown(version)}, which cannot use a database outside " <>
           "the installation. Databases outside the installation start in " <>
           "#{Install.external_since()}. Run " <>
           "`ehosctl upgrade --installation #{name}` first. ehosctl changed nothing."}
  end

  defp running_version(_unrecorded, name),
    do:
      {:error, :invalid,
       "#{name} runs an EHOS whose version ehosctl cannot read from the cluster. Run " <>
         "`ehosctl upgrade --installation #{name}` first. ehosctl changed nothing."}

  defp not_listed(listed, database, name) do
    if Enum.any?(listed || [], &(&1["name"] == database)),
      do:
        {:error, :invalid,
         "#{name} lists the database #{Refusal.shown(database)} already. This command only " <>
           "adds a database. To change or remove one, change the values of the Helm release " <>
           "with helm. ehosctl changed nothing."},
      else: :ok
  end

  defp upgrade_first(name, host_option),
    do: "run `ehosctl upgrade --installation #{name} #{host_option}` first"

  # The mail is kept as it runs; settings ehosctl did not write cannot be kept without a word.
  defp readable_mail(:unreadable, name),
    do:
      {:error, :invalid,
       "EHOS on #{name} sends mail through settings that ehosctl did not write " <>
         "(governance.mail in its Helm release). Run `ehosctl install --installation #{name}` " <>
         "with --smtp-host and --mail-from, or with --no-mail, first. ehosctl changed nothing."}

  defp readable_mail(_mail, _name), do: :ok

  defp rendered(name, listed, installed, env, opts) do
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
         "The chart of EHOS refused the database, or could not be rendered. ehosctl changed " <>
           "nothing.\n" <> String.trim_trailing(message)}
    end
  end

  defp secret_written(name, entry, {username, password}, opts) do
    platform = Keyword.get(opts, :install, EhosPlatform.Install)

    case platform.write_external_secret(
           Install.platform_options(name, opts) ++ [progress: &Ehosctl.PlatformReport.progress/1],
           entry["name"],
           username,
           password
         ) do
      {:ok, written} -> {:ok, written}
      {:error, message} -> {:error, :failed, message}
    end
  end

  defp preview(entry, name, wanted) do
    secret = "#{ExternalDatabases.namespace()}/#{entry["managingRoleSecret"]}"

    Output.lines([
      "ehosctl adds the database #{entry["name"]} outside the installation to #{name}, which " <>
        "runs EHOS #{wanted["version"]}:",
      Output.values(
        [
          {"Server", "#{entry["host"]}:#{entry["port"]}"},
          {"Database", entry["database"]},
          {"PostgreSQL", Integer.to_string(entry["version"])},
          {"Address ranges", Enum.join(entry["addressRanges"], ", ")},
          {"CA", certificates(entry["ca"])},
          {"Managing role", "In the Secret #{secret}"}
        ] ++ administrator(entry["administratorRole"])
      ),
      "ehosctl writes the Secret, then installs EHOS #{wanted["version"]} again with the " <>
        "database in its list."
    ])
  end

  defp administrator(nil), do: []
  defp administrator(role), do: [{"Administrator role", role}]

  defp certificates(pem) do
    case length(:public_key.pem_decode(pem)) do
      1 -> "1 certificate"
      count -> "#{count} certificates"
    end
  end

  # The Secret of the managing role, and, read from a file, the warning that the cluster keeps a
  # copy and that the file is the person's (ehos-tools T-30). A value from a pipe leaves no file.
  defp added(database, name, written, secret) do
    made = if written == :created, do: "made", else: "replaced"
    {values, warnings} = Output.secrets([secret])

    Output.lines(
      [
        Output.outcome(
          :done,
          "#{name} lists the database #{database} outside the installation. ehosctl #{made} " <>
            "the Secret of its managing role."
        ),
        Output.values(values)
      ] ++
        Enum.flat_map(warnings, &["", &1]) ++
        ["", Output.next(["ehosctl resources check #{database} --installation #{name}"])]
    )
  end

  defp read_from("-"), do: nil
  defp read_from(path), do: path
end
