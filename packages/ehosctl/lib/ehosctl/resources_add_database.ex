defmodule Ehosctl.ResourcesAddDatabase do
  @moduledoc """
  `ehosctl resources add-database NAME`: lists a PostgreSQL database outside the installation,
  such as one on Cloud SQL or RDS, as a resource that environments can bind (eh-os D-170, T-29).
  It runs under `ehosctl resources` (`c:Ehosctl.Command.mounted/0`), on the platform plane:
  through the kubeconfig `ehosctl server tunnel` wrote, never through EHOS's API.

  The list lives in the Helm release alone, as the other settings `install` and `upgrade` keep.
  The command runs in this order, and writes nothing before step 4:

    1. It checks each field as the chart does (`EhosPlatform.ExternalDatabases.check/1`), and
       reads the managing role's password from `--password-file`: a file, or `-`, standard input
       from a pipe or a file, never a terminal (`Ehosctl.SecretInput`). The password is never an
       argument.
    2. It reads what runs (`Ehosctl.Install.installed/2`), and refuses when nothing runs, when
       the EHOS that runs is before 0.30.0, or when it lists the name already: changing or
       removing an entry is not this command's.
    3. It renders the chart that runs with the list and the new entry
       (`EhosPlatform.Install.render_running/1`), so the chart's own refusals come first, and
       prints what it adds, without the password.
    4. It writes the managing role into the Secret `ehos-external-<name>` in `ehos-data`
       (`EhosPlatform.Install.write_external_secret/4`), which it makes, or replaces when it made
       it before for the same database.
    5. It installs the version that runs again, as `upgrade` does (`Ehosctl.Install.install/4`),
       with every other setting kept from what runs.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Install
  alias Ehosctl.Output
  alias Ehosctl.Refusal
  alias Ehosctl.SecretInput
  alias EhosPlatform.ExternalDatabases

  # eh-os D-170: the first EHOS whose chart takes `dataResources.external`.
  @since "0.30.0"
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
          "runs again, through the tunnel to the server. Needs GHCR_TOKEN.",
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
              "standard input, from a pipe or a file. ehosctl never reads it from a terminal."
        ]
      ]
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
         {:ok, ca} <- ca(parsed.options.ca_file),
         entry = entry(parsed, ca),
         :ok <- checked(entry),
         :ok <- username_checked(parsed.options.username),
         {:ok, password} <- password(parsed.options.password_file, entry["name"]),
         {:ok, installed} <- Install.installed(name, opts),
         :ok <- Install.settled(installed, name, opts),
         {:ok, wanted} <- running(installed, name),
         :ok <- not_listed(installed.external_databases, entry["name"], name),
         :ok <- Install.host_kept(nil, installed.host, name, opts, &upgrade_first(name, &1)),
         {:ok, mail} <- kept_mail(installed.mail, name),
         env = Ehosctl.SystemEnv.current().all(),
         :ok <- Install.password_given(mail, installed.mail, env, false),
         listed = (installed.external_databases || []) ++ [entry],
         :ok <- rendered(name, listed, installed, env, opts),
         :ok <- previewed(entry, name, wanted, installed),
         {:ok, written} <-
           secret_written(name, entry, {parsed.options.username, password}, opts),
         {:ok, done} <-
           Install.install(
             name,
             wanted,
             installed.host,
             opts
             |> Keyword.put(:sign_in, installed.sign_in)
             |> Keyword.put(:four_eyes, installed.four_eyes)
             |> Keyword.put(:mail, mail)
             |> Keyword.put(:allowed_domains, installed.allowed_domains)
             |> Keyword.put(:external_databases, listed)
             |> Keyword.put(:external_under_development, installed.external_under_development)
           ) do
      {:ok, %{done | text: Output.lines([added(entry["name"], name, written), done.text])}}
    end
  end

  # What it adds, on stdout before anything is written, and each entry the install leaves out.
  defp previewed(entry, name, wanted, installed) do
    Output.result(%{text: preview(entry, name, wanted), json: nil}, false)
    Install.warn_left_out(installed)
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

  # What runs, as `Ehosctl.Install.install/4` installs it again: by its recorded release, from
  # EHOS #{@since} on.
  defp running(%{running: :none}, name),
    do:
      {:error, :invalid,
       "#{name} runs no EHOS, so it has no list of resources. Run `ehosctl install " <>
         "--installation #{name}` first. ehosctl changed nothing."}

  defp running(%{running: %{"version" => version} = running, digest: digest}, name)
       when is_binary(digest) do
    if since?(version),
      do: {:ok, Map.put(running, "digest", digest)},
      else:
        {:error, :invalid,
         "#{name} runs EHOS #{Refusal.shown(version)}, which cannot use a database outside " <>
           "the installation. Databases outside the installation start in #{@since}. Run " <>
           "`ehosctl upgrade --installation #{name}` first. ehosctl changed nothing."}
  end

  defp running(_unrecorded, name),
    do:
      {:error, :invalid,
       "#{name} runs an EHOS whose version or image ehosctl cannot read from the cluster. Run " <>
         "`ehosctl upgrade --installation #{name}` first. ehosctl changed nothing."}

  defp since?(version) do
    case Version.parse(version) do
      {:ok, parsed} -> Version.compare(parsed, Version.parse!(@since)) != :lt
      :error -> false
    end
  end

  defp not_listed(listed, database, name) do
    if Enum.any?(listed || [], &(&1["name"] == database)),
      do:
        {:error, :invalid,
         "#{name} lists the database #{Refusal.shown(database)} already. This command only " <>
           "adds a database. To change or remove one, change the values of the Helm release " <>
           "with helm, or install again. ehosctl changed nothing."},
      else: :ok
  end

  defp upgrade_first(name, host_option),
    do: "run `ehosctl upgrade --installation #{name} #{host_option}` first"

  # The mail is kept as it runs; settings ehosctl did not write cannot be kept without a word.
  defp kept_mail(:unreadable, name),
    do:
      {:error, :invalid,
       "EHOS on #{name} sends mail through settings that ehosctl did not write " <>
         "(governance.mail in its Helm release). Run `ehosctl install --installation #{name}` " <>
         "with --smtp-host and --mail-from, or with --no-mail, first. ehosctl changed nothing."}

  defp kept_mail(mail, _name), do: {:ok, mail}

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
            progress: &Output.progress/1
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
           Install.platform_options(name, opts) ++ [progress: &Output.progress/1],
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

  defp added(database, name, written) do
    secret = if written == :created, do: "made", else: "replaced"

    Output.lines([
      Output.outcome(
        :done,
        "#{name} lists the database #{database} outside the installation. ehosctl #{secret} " <>
          "the Secret of its managing role."
      ),
      Output.next(["ehosctl resources check #{database} --installation #{name}"])
    ])
  end
end
