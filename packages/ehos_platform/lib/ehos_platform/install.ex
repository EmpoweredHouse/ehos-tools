defmodule EhosPlatform.Install do
  @moduledoc """
  Installs EHOS into a Kubernetes cluster named by a kubeconfig context (D-79): the code that
  `mix ehos.cluster up` runs after it creates k3d, and that `mix ehos.install` runs on a server.

  An installation is two steps (D-30): the prerequisite releases, then the distribution chart.

    * `prerequisites/1` installs CloudNativePG (D-30), cert-manager and trust-manager (D-59) at
      their pinned versions;
    * `certificate_authority/1` makes the installation's own CA, whose name constraints and
      admission policy admit the console's host and the names under it alone (D-45, D-62);
    * `name_in_cluster/1` gives pods the console's host and every name under it, so they reach
      the console and applications through the ingress without leaving the cluster (D-45);
    * `chart/2` installs or upgrades the chart and waits until the console's certificate is
      issued.

  The CA and the CoreDNS rule are this package's `priv/manifests/local-ca.yaml` and
  `priv/manifests/coredns-custom.yaml`, written for `ehos.localhost` and rendered with the target's
  host, which for `ehos.localhost` changes nothing, so the local cluster runs the rendering a server
  runs. The chart comes from the target's `EhosPlatform.Source`: a checkout's directory, packaged
  here, or a release's chart by digest (eh-os D-92).

  Every `helm` and `kubectl` call names the target's context, and its kubeconfig when it has one,
  so no other cluster is ever touched. Everything runs through `EhosPlatform.CommandRunner`.
  """

  alias EhosPlatform.CommandRunner
  alias EhosPlatform.Server
  alias EhosPlatform.Source
  alias EhosPlatform.TmpDir

  @local_ca "local-ca.yaml"
  @coredns_custom "coredns-custom.yaml"
  @traefik_client_addresses "traefik-client-addresses.yaml"
  # The annotation on CoreDNS's pod template that holds the hash of the rule its pods took.
  @coredns_rule "ehos.empowered.house/coredns-rule"
  @local_host "ehos.localhost"
  @namespace "ehos-system"

  # D-30: CloudNativePG is a prerequisite release, pinned here, by the digest of its OCI chart as
  # the other two are (#220): the same chart as the HTTPS repository's 0.29.1, compared file by file.
  @cnpg_version "0.29.1"
  @cnpg_chart "oci://ghcr.io/cloudnative-pg/charts/cloudnative-pg@sha256:3245fa051bb21d0dd9246272f57a2760b4234817a164a3167d2a1e7fb9f63fd9"

  # D-45: cert-manager is a prerequisite of an installation, not of the chart. Its chart is pulled
  # by the digest of v1.21.2's OCI artifact, so what installs is exactly what was checked.
  @cert_manager_version "v1.21.2"
  @cert_manager_chart "oci://quay.io/jetstack/charts/cert-manager@sha256:634dce9c13b56677a2c05e2ab76c312d0be2664022d5dd05815da67e1fd5f610"
  @cert_manager_namespace "cert-manager"

  # D-59: trust-manager copies the data CA's certificate, and EHOS's, into every environment's
  # namespace. Its trust namespace is cert-manager's, where the data CA's key is kept; it writes
  # ConfigMaps only, and installs no public trust bundle, which nothing here uses.
  @trust_manager_version "v0.25.0"
  @trust_manager_chart "oci://quay.io/jetstack/charts/trust-manager@sha256:ef4540d4c3b7eb8cd498e3420aa5171ccc7434b7fa5e3168f1218d22906dbecb"

  # D-62: the CA's Certificate and Secret, in cert-manager's namespace, and the ClusterIssuer that
  # signs from it.
  @ca_name "ehos-local-ca"
  @tls_secret "ehos-governance-tls"
  # D-55: the pull credential for a private registry, in EHOS's namespace.
  @pull_credential "ehos-pull-credential"
  # eh-os D-36: the SMTP server's password, in EHOS's namespace, which the chart names.
  @smtp_secret "ehos-smtp"
  # On that Secret while the governance plane still reads the password before it, so a run that
  # failed after writing it restarts the plane on the next.
  @restart_pending "ehos.empowered.house/restart"

  # How the operator runs the server's commands, and names an installation in them, for the
  # sentences that name them.
  @server_command "mix ehos.server"
  @name_option "--name"

  @enforce_keys [:context, :host, :source]
  defstruct @enforce_keys ++
              [
                kubeconfig: nil,
                runner: CommandRunner.System,
                progress: &__MODULE__.quiet/1,
                sleep: &Process.sleep/1,
                server_command: @server_command
              ]

  @typedoc "The cluster EHOS is installed into, and the console's host there."
  @type t :: %__MODULE__{
          context: String.t(),
          host: String.t(),
          source: Source.t(),
          kubeconfig: Path.t() | nil,
          runner: module(),
          progress: (String.t() -> any()),
          sleep: (non_neg_integer() -> any()),
          server_command: String.t()
        }

  @doc false
  def quiet(_line), do: :ok

  @doc "The CA's name, which is also its `ClusterIssuer`'s and its Secret's."
  @spec ca_name() :: String.t()
  def ca_name, do: @ca_name

  @typedoc "The outcome of a command, with a sentence an operator can act on."
  @type result :: {:ok, String.t()} | {:error, String.t()}

  @registry "ghcr.io"
  @repository "ghcr.io/empoweredhouse/ehos"

  @doc """
  Installs, or upgrades, EHOS on an installation's server (`mix ehos.install`), through the
  kubeconfig `mix ehos.server tunnel` wrote in `~/.ehos/<name>` and its context `ehos-<name>`.

  The console's host is `ehos.<a-b-c-d>.sslip.io`, from the address the tunnel goes to, so no
  domain is needed: sslip.io answers every name under it with that address. The image is the
  published one, by digest, from GHCR, whose packages are private: the pull credential is written
  from `GHCR_TOKEN`, a classic token with `read:packages` alone, and kept in the cluster, so a
  later run needs no token unless it replaces it.

  ## Options

    * `:digest` — the image's digest, `sha256:…`: the index CI published (required).
    * `:source` — what is installed, an `EhosPlatform.Source` (required).
    * `:name` and `:home` — the installation, as for `EhosPlatform.Server`. Default to `trial` and
      `~/.ehos`.
    * `:host` — the console's host, instead of the one the tunnel's address gives.
    * `:sign_in` — how long a sign-in to an application lasts (eh-os D-113): a map of
      `"absolute"` and `"idle"`, each in hours or days (`"30d"`), written into the chart's
      `governance.signIn`. A key left out is the chart's default; none, both are (12h and 1h).
    * `:four_eyes` — whether a promotion to production needs a second person (eh-os D-105):
      `true` or `false`, written into the chart's `governance.promotion.fourEyes`. None is the
      chart's default, `true`.
    * `:mail` — the SMTP server EHOS sends mail through (eh-os D-36): a map of `"from"` and
      `"smtp"`, itself of `"host"`, `"port"` and, when it authenticates, `"username"`, written into
      the chart's `governance.mail`. None: EHOS sends no mail. TLS stays on and verified.
    * `:smtp_password` — the SMTP user's password, written into the Secret `#{@smtp_secret}` the
      chart reads it from. Without it, the one the cluster holds is kept; a `:mail` with a
      `"username"` and neither is refused before anything changes.
    * `:installed` — what is installed, as `installed/1` reads it back: a map of `version`,
      `image` and `chart`, written into the Helm release's values (eh-os D-92). None writes none.
    * `:server_command` — how the operator runs the server's commands, for the sentences that
      name them: `mix ehos.server` unless given (`ehosctl server` for `ehosctl`).
    * `:name_option` and `:name_in_commands` — as for `EhosPlatform.Server`: whether a command
      those sentences suggest names the installation, and with which option (`--name` unless
      given). Defaults to false.
    * `:token` — the pull credential's token. Defaults to `GHCR_TOKEN`.
    * `:username` — the GitHub user the token belongs to. Defaults to `GHCR_USERNAME`, or the
      GitHub CLI's user.
    * `:runner`, `:progress`, `:sleep` — as for `EhosPlatform.Server`.
  """
  @spec server(keyword()) :: result()
  def server(opts) do
    name = Keyword.get(opts, :name, "trial")

    if Server.valid_name?(name),
      do: install_server(name, opts),
      else: {:error, Server.name_rule()}
  end

  defp install_server(name, opts) do
    dir = opts |> Keyword.get(:home, "~/.ehos") |> Path.expand() |> Path.join(name)
    runner = Keyword.get(opts, :runner, CommandRunner.System)
    progress = Keyword.get(opts, :progress, &quiet/1)
    server_command = Keyword.get(opts, :server_command, @server_command)
    tunnel = tunnel_command(opts)
    ca_file = Path.join(dir, "ca.crt")

    with {:ok, digest} <- digest(Keyword.get(opts, :digest)),
         {:ok, kubeconfig} <- kubeconfig(dir, tunnel),
         {:ok, host} <- host(opts, dir, tunnel),
         target = %__MODULE__{
           context: "ehos-#{name}",
           host: host,
           source: Keyword.fetch!(opts, :source),
           kubeconfig: kubeconfig,
           runner: runner,
           progress: progress,
           sleep: Keyword.get(opts, :sleep, &Process.sleep/1),
           server_command: server_command
         },
         :ok <- reachable(target, tunnel),
         {:ok, smtp_password} <- smtp_password(target, opts),
         {:ok, registry_auth} <- credential(target, opts),
         :ok <- smtp_written(target, smtp_password),
         :ok <- prerequisites(target),
         :ok <- certificate_authority(target),
         :ok <- name_in_cluster(target),
         {:ok, installation} <- Server.description(dir, name),
         {:ok, pem} <- ca_pem(target),
         :ok <- write_file(ca_file, pem),
         :ok <-
           chart(target,
             repository: @repository,
             digest: digest,
             ca_file: ca_file,
             allowed_image_prefixes: ["ghcr.io/empoweredhouse/"],
             pull_credential?: true,
             own_pull_credential?: true,
             installation: installation,
             installed: Keyword.get(opts, :installed),
             sign_in: Keyword.get(opts, :sign_in),
             four_eyes: Keyword.get(opts, :four_eyes),
             mail: Keyword.get(opts, :mail),
             registry_auth: registry_auth
           ),
         :ok <-
           write_file(
             Path.join(dir, "install.json"),
             Jason.encode_to_iodata!(
               %{"digest" => digest, "host" => host, "repository" => @repository},
               pretty: true
             )
           ),
         # After what runs is recorded: a restart that fails leaves the record true, and the
         # Secret marked, so the next run restarts the plane again.
         :ok <- restart_for_password(target, smtp_password) do
      {:ok,
       "EHOS is running at https://#{host} (image #{@repository}@#{digest}). Its certificate " <>
         "is signed by the installation's CA, in #{ca_file}: trust it to open the console " <>
         "without a warning. Invite a person with #{suggested(opts, "invite <their email>")}, " <>
         "which prints the link that signs them in: the first one " <>
         "invited while nobody is the platform's administrator becomes it."}
    end
  end

  # D-79: the installation's CA certificate and what it runs, `install.json`, are kept beside its
  # other files, so the next upgrade starts from them.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_file(path, contents) do
    case File.write(path, contents) do
      :ok -> :ok
      {:error, reason} -> {:error, "#{path} cannot be written: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  The image's digest when it is one, `sha256:` and 64 hex digits, as CI publishes it; checked
  before anything uses it, `mix ehos.server.check` among them, before it makes a server.
  """
  @spec digest(String.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def digest(digest) when is_binary(digest) do
    if digest =~ ~r/\Asha256:[0-9a-f]{64}\z/,
      do: {:ok, digest},
      else: {:error, "--digest must be sha256: and 64 hex digits, the index CI published"}
  end

  def digest(nil),
    do:
      {:error,
       "Give --digest: the image's index, as `sha256:…`, from the summary of CI's Publish index " <>
         "job on main"}

  @typedoc """
  The SMTP server EHOS sends mail through (eh-os D-36), as the chart's `governance.mail` holds it,
  without the password: the sender, and the server's host, port and the user it authenticates as,
  when it does.
  """
  @type mail :: %{
          String.t() => String.t() | %{String.t() => String.t() | pos_integer()}
        }

  @typedoc """
  What runs on an installation's server, as `installed/1` reads it from the Helm release:

    * `:running` — `:none` where no revision of EHOS was ever deployed, `:unknown` where one was by
      something that recorded nothing, such as `mix ehos.install` before eh-os Stage 13, or what
      `server/1` recorded: a map of `"version"`, `"image"` and `"chart"`;
    * `:digest` — the image's digest that revision runs, `sha256:…`, or `nil`;
    * `:host` — the console's host that revision serves, or `nil`;
    * `:sign_in` — the sign-in limits that revision was given (eh-os D-113), a map of `"absolute"`
      and/or `"idle"` in hours or days, or `nil` when it was given none and runs the chart's;
    * `:four_eyes` — whether that revision's promotions need a second person (eh-os D-105), as
      its `governance.promotion.fourEyes` says, however it was set; `nil` when it was given none
      and runs the chart's;
    * `:mail` — the SMTP server that revision sends mail through (eh-os D-36), as `server/1`'s
      `:mail` takes it, without the password, which stays in its Secret; `nil` when it sends none,
      and `:unreadable` when its settings are not ones `server/1` writes;
    * `:last` — the release's last revision when it is not the one that runs: its `:revision`,
      `:status` (`failed`, `pending-upgrade`, …) and Helm's `:description` of it; else `nil`.
  """
  @type installed :: %{
          running: :none | :unknown | %{String.t() => String.t()},
          digest: String.t() | nil,
          host: String.t() | nil,
          sign_in: %{optional(String.t()) => String.t()} | nil,
          four_eyes: boolean() | nil,
          mail: mail() | :unreadable | nil,
          last: %{revision: pos_integer(), status: String.t(), description: String.t()} | nil
        }

  @doc """
  What runs on an installation's server (`t:installed/0`), as `server/1` recorded it in the Helm
  release's values (eh-os D-92), read through the kubeconfig `tunnel` wrote: never through EHOS's
  API, which needs a credential.

  It is read from the release's last *deployed* revision, found in its history: the last revision
  may be one that failed, or one still pending, and its values say what was asked, not what runs.
  That revision is then `:last`.

  Options as `server/1`'s: `:name`, `:home`, `:runner`, `:server_command`, `:name_option`,
  `:name_in_commands`.
  """
  @spec installed(keyword()) :: {:ok, installed()} | {:error, String.t()}
  def installed(opts) do
    name = Keyword.get(opts, :name, "trial")
    dir = opts |> Keyword.get(:home, "~/.ehos") |> Path.expand() |> Path.join(name)
    runner = Keyword.get(opts, :runner, CommandRunner.System)

    with true <- Server.valid_name?(name) || {:error, Server.name_rule()},
         {:ok, kubeconfig} <-
           kubeconfig(dir, tunnel_command(opts)) do
      on_release = [
        "ehos",
        "--namespace",
        @namespace,
        "--output",
        "json",
        "--kube-context",
        "ehos-#{name}",
        "--kubeconfig",
        kubeconfig
      ]

      case history(runner, on_release, opts) do
        {:ok, []} ->
          {:ok,
           %{
             running: :none,
             digest: nil,
             host: nil,
             sign_in: nil,
             four_eyes: nil,
             mail: nil,
             last: nil
           }}

        {:ok, revisions} ->
          deployed = revisions |> Enum.filter(&(&1.status == "deployed")) |> List.last()
          last = List.last(revisions)
          last = if last != deployed, do: last

          case deployed do
            nil ->
              {:ok,
               %{
                 running: :none,
                 digest: nil,
                 host: nil,
                 sign_in: nil,
                 four_eyes: nil,
                 mail: nil,
                 last: last
               }}

            %{revision: revision} ->
              with {:ok, values} <- values(runner, on_release, revision, opts),
                   do: {:ok, Map.put(recorded(values), :last, last)}
          end

        error ->
          error
      end
    end
  end

  # The release's revisions, oldest first; none when there is no release.
  defp history(runner, on_release, opts) do
    case runner.run("helm", ["history" | on_release]) do
      {output, 0} ->
        case last_json(output) do
          {:ok, revisions} when is_list(revisions) ->
            revisions(revisions, output)

          _other ->
            {:error,
             "`helm history` gave something other than the release's revisions:\n" <> output}
        end

      {output, status} = result when is_integer(status) ->
        if String.contains?(output, "release: not found"),
          do: {:ok, []},
          else: tunnel_hint(failure("helm", result), opts)

      result ->
        failure("helm", result)
    end
  end

  defp revisions(listed, output) do
    revisions =
      for %{"revision" => revision, "status" => status} = listed <- listed,
          is_integer(revision) and revision > 0 and is_binary(status) do
        description = listed["description"]

        %{
          revision: revision,
          status: status,
          description: if(is_binary(description), do: description, else: "")
        }
      end

    if length(revisions) == length(listed),
      do: {:ok, Enum.sort_by(revisions, & &1.revision)},
      else: {:error, "`helm history` gave a revision without its number or status:\n" <> output}
  end

  defp values(runner, on_release, revision, opts) do
    case runner.run("helm", ["get", "values" | on_release] ++ ["--revision", "#{revision}"]) do
      {output, 0} ->
        case last_json(output) do
          {:ok, values} when is_map(values) or is_nil(values) ->
            {:ok, values || %{}}

          _other ->
            {:error,
             "`helm get values` gave something other than the release's values:\n" <> output}
        end

      {_output, status} = result when is_integer(status) ->
        tunnel_hint(failure("helm", result), opts)

      result ->
        failure("helm", result)
    end
  end

  defp tunnel_hint({:error, message}, opts),
    do: {:error, message <> "\nIs the tunnel open? #{tunnel_command(opts)} opens it."}

  # The command that opens the tunnel, quoted, as the operator runs the server's commands
  # (`:server_command`), and naming the installation when the caller asks (`:name_in_commands`):
  # without it, the command reaches whichever installation is the operator's default.
  defp tunnel_command(opts), do: suggested(opts, "tunnel")

  # A command of the server's to suggest, quoted, built as `tunnel_command/1` says.
  defp suggested(opts, subcommand) do
    command = Keyword.get(opts, :server_command, @server_command)

    named =
      if Keyword.get(opts, :name_in_commands, false),
        do:
          " #{Keyword.get(opts, :name_option, @name_option)} #{Keyword.get(opts, :name, "trial")}",
        else: ""

    "`#{command} #{subcommand}#{named}`"
  end

  # helm prints its answer as one line of JSON, `null` for no values, among any warnings it gives:
  # the last line that is JSON is it.
  defp last_json(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value(:error, fn line ->
      case Jason.decode(line) do
        {:ok, value} -> {:ok, value}
        {:error, _} -> nil
      end
    end)
  end

  defp recorded(values) do
    running =
      case values do
        %{"installed" => %{"version" => v, "image" => i, "chart" => c} = installed}
        when is_binary(v) and is_binary(i) and is_binary(c) ->
          Map.take(installed, ["version", "image", "chart"])

        _nothing ->
          :unknown
      end

    digest =
      case at(values, ["image", "digest"]) do
        digest when is_binary(digest) -> if digest =~ ~r/\Asha256:[0-9a-f]{64}\z/, do: digest
        _none -> nil
      end

    host =
      case at(values, ["governance", "host"]) do
        host when is_binary(host) -> if match?({:ok, _}, host(host)), do: host
        _none -> nil
      end

    %{
      running: running,
      digest: digest,
      host: host,
      sign_in: sign_in(values),
      four_eyes: four_eyes(values),
      mail: mail(values)
    }
  end

  # eh-os D-105: read as the chart reads it, so a value set by hand with `helm --set`, as an
  # installation of one person had to before ehos-tools#296, is kept too: only `false` turns four
  # eyes off, anything else keeps them on.
  defp four_eyes(values) do
    case at(values, ["governance", "promotion", "fourEyes"]) do
      nil -> nil
      value -> value not in [false, "false"]
    end
  end

  # eh-os D-113: what `server/1` wrote, each value as the chart takes it; anything else is not
  # carried into the next install, which then runs the chart's default for it.
  defp sign_in(values) do
    case at(values, ["governance", "signIn"]) do
      %{} = given ->
        limits =
          for {key, value} <- given,
              key in ["absolute", "idle"],
              is_binary(value) and sign_in_limit?(value),
              into: %{},
              do: {key, value}

        if limits == %{}, do: nil, else: limits

      _none ->
        nil
    end
  end

  @doc """
  Whether `value` is a sign-in limit the chart takes (eh-os D-113): whole hours or days, `12h` or
  `30d`, at most four digits.
  """
  @spec sign_in_limit?(String.t()) :: boolean()
  def sign_in_limit?(value) when is_binary(value), do: value =~ ~r/\A[1-9][0-9]{0,3}[hd]\z/
  def sign_in_limit?(_value), do: false

  # eh-os D-36: what `server/1` wrote, as the chart takes it, the port the chart's 587 where none
  # was written; none where the revision sends no mail. Settings `server/1` would not have written,
  # as a hand-made `helm --set` may leave them (a sender or port it would refuse, TLS turned off,
  # the password in another Secret), are `:unreadable`, never none or a map without them: the next
  # install would otherwise turn mail off, or TLS back on, without a word.
  defp mail(values) do
    from = at(values, ["governance", "mail", "from"])
    host = at(values, ["governance", "mail", "smtp", "host"])
    port = at(values, ["governance", "mail", "smtp", "port"]) || 587
    username = at(values, ["governance", "mail", "smtp", "username"])
    tls = at(values, ["governance", "mail", "smtp", "tls"])
    secret = at(values, ["governance", "mail", "smtp", "password", "secretName"])

    with true <- host not in [nil, ""] || :none,
         # TLS turned off, or the password kept elsewhere, by hand: never undone without a word.
         true <- tls in [nil, true] and secret in [nil, "", @smtp_secret],
         true <- mail_host?(host) and mail_address?(from),
         true <- is_integer(port) and port in 1..65_535,
         true <- username in [nil, ""] or mail_username?(username) do
      smtp = %{"host" => host, "port" => port}
      smtp = if username in [nil, ""], do: smtp, else: Map.put(smtp, "username", username)
      %{"from" => from, "smtp" => smtp}
    else
      :none -> nil
      _not_written_here -> :unreadable
    end
  end

  # A DNS label: letters, digits and inner hyphens, at most 63 of them.
  @label "[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"

  @doc """
  Whether `value` is an SMTP server's host EHOS takes: a DNS name, its labels separated by single
  dots. The mailer checks the server's certificate against it.
  """
  @spec mail_host?(term()) :: boolean()
  def mail_host?(value) when is_binary(value),
    do: byte_size(value) <= 253 and value =~ ~r/\A#{@label}(?:\.#{@label})*\z/

  def mail_host?(_value), do: false

  @doc """
  Whether `value` is an address EHOS may send mail from: printable ASCII, one `@` between a local
  part and a DNS name, and no space, quote, angle bracket or comma, which would change the header.
  An address beyond ASCII would need SMTPUTF8, which EHOS's mailer does not ask for.
  """
  @spec mail_address?(term()) :: boolean()
  def mail_address?(value) when is_binary(value) do
    with true <- byte_size(value) <= 254,
         [local, domain] <- String.split(value, "@"),
         # A dot-atom: dots only between atext, never first, last or doubled.
         true <- local =~ ~r/\A[!#-'*+\-\/-9=?A-Z^-~]+(?:\.[!#-'*+\-\/-9=?A-Z^-~]+)*\z/,
         true <- byte_size(local) <= 64,
         true <- mail_host?(domain) and String.contains?(domain, ".") do
      true
    else
      _not_an_address -> false
    end
  end

  def mail_address?(_value), do: false

  @doc "Whether `value` is an SMTP user EHOS takes: printable ASCII without spaces, at most 254."
  @spec mail_username?(term()) :: boolean()
  def mail_username?(value) when is_binary(value),
    do: byte_size(value) <= 254 and value =~ ~r/\A[!-~]+\z/

  def mail_username?(_value), do: false

  # A value under `keys` of nested maps, or `nil` where any of them is something else.
  defp at(value, []), do: value
  defp at(%{} = map, [key | keys]), do: at(Map.get(map, key), keys)
  defp at(_value, _keys), do: nil

  # The release command waits for the governance database and boots EHOS's code; a tunnel that is
  # wedged would otherwise keep `kubectl exec` waiting for ever.
  @invite_timeout :timer.minutes(2)

  @typedoc """
  What EHOS printed when it invited a person (`invite/1`):

    * `:invited` — its line that says whom it invited and for how long the link signs them in;
    * `:link` — the link, which signs them in once: a password;
    * `:administrator` — its line that says the person became the platform's administrator, since
      nobody was (eh-os D-37), or `nil`;
    * `:interrupted` — when kubectl failed after EHOS printed the link, a sentence that says so,
      since what EHOS printed after the link, its administrator's line among it, may be missing;
      else `nil`.
  """
  @type invited :: %{
          invited: String.t(),
          link: String.t(),
          administrator: String.t() | nil,
          interrupted: String.t() | nil
        }

  @doc """
  Invites the person `:email` names on an installation's server, and returns the link EHOS
  printed, which signs them in once, within 15 minutes (eh-os D-35).

  It is EHOS's release command, `bin/ehos eval` of `Ehos.Release.invite/1`, run with `kubectl
  exec` in the governance container, through the kubeconfig `tunnel` wrote in `~/.ehos/<name>`
  and its context `ehos-<name>`. When nobody is the platform's administrator yet, EHOS makes the
  person invited it. A person who has joined is not refused, as EHOS's API and console refuse
  them: the link signs them in again, which is how one who forgot their password gets back in
  while the installation sends no mail (eh-os#441).

  The address goes into the expression EHOS evaluates, so it is checked with `email/1` and written
  as an Elixir string literal by `invite_expression/1`, never pasted into the code.

  The link is returned, and written nowhere: whoever reads it can sign in as that person.

  ## Options

    * `:email` — the person's address (required).
    * `:name`, `:home`, `:runner`, `:server_command`, `:name_option`, `:name_in_commands` — as
      for `server/1`.
  """
  @spec invite(keyword()) :: {:ok, invited()} | {:error, String.t()}
  def invite(opts) do
    name = Keyword.get(opts, :name, "trial")
    dir = opts |> Keyword.get(:home, "~/.ehos") |> Path.expand() |> Path.join(name)
    runner = Keyword.get(opts, :runner, CommandRunner.System)

    with true <- Server.valid_name?(name) || {:error, Server.name_rule()},
         {:ok, expression} <- invite_expression(Keyword.fetch!(opts, :email)),
         {:ok, kubeconfig} <- kubeconfig(dir, tunnel_command(opts)) do
      args = [
        "--kubeconfig",
        kubeconfig,
        "--context",
        "ehos-#{name}",
        "--namespace",
        @namespace,
        "exec",
        "deployment/ehos-governance",
        "--container",
        "governance",
        "--",
        "bin/ehos",
        "eval",
        expression
      ]

      "kubectl"
      |> runner.run_bounded(args, @invite_timeout)
      |> invited(opts)
    end
  end

  @doc """
  `email` when it is an address EHOS could take for a person, as eh-os's `Ehos.Accounts.Person`
  checks one: an `@` with something on each side and no other, no space, comma or semicolon, at
  most 160 characters. It refuses more than EHOS does: bytes that are not UTF-8, and a control
  or format character, a line or paragraph separator, or a space of Unicode's, such as U+00A0.
  EHOS would take those, but a terminal acts on them, or they hide or reorder the text around
  them, and an address that holds one, pasted by mistake, would be invited as another person.

  This refuses early what EHOS would refuse. What keeps an address from running as code is
  `invite_expression/1`'s string literal, which takes a quote, a backslash or `\#{` as they are.

      iex> EhosPlatform.Install.email("ada@example.com")
      {:ok, "ada@example.com"}

      iex> EhosPlatform.Install.email("ada@example.com,alan@example.com")
      {:error, ~S|"ada@example.com,alan@example.com" is not an email address EHOS takes: one @ with something on each side, and no space, comma or semicolon|}
  """
  @spec email(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def email(email) when is_binary(email) do
    cond do
      not printable?(email) or String.match?(email, ~r/\p{Z}/u) ->
        {:error,
         "#{inspect(email)} is not an email address EHOS takes: it holds bytes that are not " <>
           "UTF-8, a control or formatting character, or a space"}

      # EHOS's own expression, without Unicode's classes, as EHOS runs it.
      not String.match?(email, ~r/\A[^@,;\s]+@[^@,;\s]+\z/) ->
        {:error,
         "#{inspect(email)} is not an email address EHOS takes: one @ with something on each " <>
           "side, and no space, comma or semicolon"}

      # Counted in code points, as EHOS counts them.
      length(String.codepoints(email)) > 160 ->
        {:error, "The email address is longer than the 160 characters EHOS takes"}

      true ->
        {:ok, email}
    end
  end

  @doc """
  The Elixir expression EHOS evaluates to invite `email` (`invite/1`), once `email/1` has taken
  it: a call of `Ehos.Release.invite/1` whose one argument is a string literal, written by
  `inspect/2`, which escapes a quote, a backslash and `\#{`. The expression is parsed back before
  it is returned, and must be that call with that very string and nothing else.

      iex> EhosPlatform.Install.invite_expression(~S|a"b@example.com|)
      {:ok, ~S|Ehos.Release.invite("a\\"b@example.com")|}
  """
  @spec invite_expression(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def invite_expression(email) do
    with {:ok, email} <- email(email) do
      expression = "Ehos.Release.invite(" <> inspect(email, printable_limit: :infinity) <> ")"

      case Code.string_to_quoted(expression) do
        {:ok, {{:., _, [{:__aliases__, _, [:Ehos, :Release]}, :invite]}, _, [^email]}} ->
          {:ok, expression}

        _other ->
          {:error, "#{inspect(email)} cannot be written as an Elixir string for EHOS to take"}
      end
    end
  end

  # What `Ehos.Release.invite/1` printed, read whatever kubectl's exit status: a stream that
  # broke after EHOS printed the link still invited the person, and the link is theirs.
  defp invited({output, status}, opts) when is_integer(status) do
    email = Keyword.fetch!(opts, :email)

    case {printed(output), status} do
      {{:ok, invited}, 0} ->
        {:ok, invited}

      {{:ok, invited}, status} ->
        {:ok,
         %{
           invited
           | interrupted:
               "kubectl failed with exit status #{status} after EHOS printed the link, so what " <>
                 "EHOS said after it may be missing: if nobody was the platform's " <>
                 "administrator, this person is now."
         }}

      {:error, 0} ->
        {:error,
         "EHOS ran the invitation of #{email} but printed no sign-in link in the form this " <>
           "version knows. What it printed is below; a link in it is a password, for that " <>
           "person alone:\n" <> output}

      {:error, status} ->
        # An exception EHOS raised, as `Ehos.Release.invite/1` raises for a person who is
        # disabled or an address it refuses: its first line says why. Anything else is said as
        # kubectl printed it, but for a sign-in link, which is a password.
        case Regex.run(~r/^\*\* (\(.+)$/m, output) do
          [_line, raised] ->
            {:error, "EHOS did not invite #{email}: #{hidden(raised)}"}

          nil ->
            tunnel_hint(failure("kubectl", {hidden(output), status}), opts)
        end
    end
  end

  defp invited({:error, :timeout}, opts),
    do:
      tunnel_hint(
        {:error,
         "kubectl did not finish within #{div(@invite_timeout, 60_000)} minutes, and no link " <>
           "reached ehosctl. EHOS may still have invited them, and made them administrator if nobody was: " <>
           "run it again for a link."},
        opts
      )

  defp invited(result, _opts), do: failure("kubectl", result)

  # EHOS's line that names the person, then the link: on a later line, not always the next, since
  # stdout and stderr come through kubectl as two streams and a log line may fall between them.
  # Then one more line when the person became administrator.
  defp printed(output) do
    lines = output |> String.replace("\r\n", "\n") |> String.split("\n")

    with [invited_line | rest] <-
           Enum.drop_while(lines, &(not String.starts_with?(&1, "Invited "))),
         true <- String.ends_with?(invited_line, ":") and printable?(invited_line),
         link when is_binary(link) <- rest |> Enum.map(&String.trim/1) |> Enum.find(&link?/1) do
      administrator =
        Enum.find(
          rest,
          &(String.starts_with?(&1, "Nobody was administrator yet:") and printable?(&1))
        )

      {:ok, %{invited: invited_line, link: link, administrator: administrator, interrupted: nil}}
    else
      _unrecognized -> :error
    end
  end

  # `text` with any sign-in link's token hidden.
  defp hidden(text), do: String.replace(text, ~r{/people/log-in/\S+}, "/people/log-in/[hidden]")

  # The length of the token EHOS writes into a sign-in link: 32 random bytes, in URL-safe Base64
  # without padding (eh-os's `Ehos.Accounts.PersonToken`).
  @token_size 43

  # The link EHOS's log-in page takes, as `Ehos.Release` writes it: an http or https URL to a
  # host, whose path is the log-in page's followed by the token.
  defp link?(link) do
    # A token cut short, as a stream broken in the middle of the line leaves it, is not one.
    printable?(link) and String.match?(link, ~r{/people/log-in/[A-Za-z0-9_-]+\z}) and
      match?(
        {:ok,
         %URI{
           scheme: scheme,
           host: host,
           path: "/people/log-in/" <> token,
           query: nil,
           fragment: nil
         }}
        when scheme in ["http", "https"] and is_binary(host) and host != "" and
               byte_size(token) >= @token_size,
        URI.new(link)
      )
  end

  # Text a terminal shows as it is: UTF-8, with no control character, which could move the cursor
  # or rewrite a line, and no format character or separator, which reorders or breaks the text.
  defp printable?(text),
    do:
      String.valid?(text) and String.printable?(text) and
        not String.match?(text, ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u)

  defp kubeconfig(dir, tunnel) do
    path = Path.join(dir, "kubeconfig")

    if File.exists?(path),
      do: {:ok, path},
      else: {:error, "#{path} is missing. Open the tunnel first: #{tunnel}"}
  end

  defp host(opts, dir, tunnel) do
    case Keyword.get(opts, :host) do
      nil ->
        case address_in(dir) do
          nil ->
            {:error,
             "The server's address is unknown: open the tunnel first (#{tunnel}), " <>
               "or give --host"}

          address ->
            {:ok, sslip_host(address)}
        end

      host ->
        host(host)
    end
  end

  @doc """
  The IPv4 address the installation's tunnel last went to, as `tunnel` recorded it in
  `tunnel.json`, or `nil`. Options `:name` and `:home`, as `server/1`'s.
  """
  @spec tunnel_address(keyword()) :: String.t() | nil
  def tunnel_address(opts) do
    opts
    |> Keyword.get(:home, "~/.ehos")
    |> Path.expand()
    |> Path.join(Keyword.get(opts, :name, "trial"))
    |> address_in()
  end

  # Read as `tunnel` reads its own record: a small regular file alone (#285).
  defp address_in(dir) do
    with %{"address" => address} when is_binary(address) <-
           Server.read_tunnel(Path.join(dir, "tunnel.json")),
         {:ok, _ip} <- :inet.parse_ipv4strict_address(String.to_charlist(address)) do
      address
    else
      _none -> nil
    end
  end

  @doc """
  The console's host sslip.io answers with `address`, the one a first install takes.

      iex> EhosPlatform.Install.sslip_host("92.5.3.194")
      "ehos.92-5-3-194.sslip.io"
  """
  @spec sslip_host(String.t()) :: String.t()
  def sslip_host(address), do: "ehos.#{String.replace(address, ".", "-")}.sslip.io"

  @doc """
  The address a console's host of sslip.io names, `ehos.<a-b-c-d>.sslip.io`, or `nil` for any other
  host.

      iex> EhosPlatform.Install.sslip_address("ehos.92-5-3-194.sslip.io")
      "92.5.3.194"

      iex> EhosPlatform.Install.sslip_address("ehos.example.org")
      nil
  """
  @spec sslip_address(String.t() | nil) :: String.t() | nil
  def sslip_address(host) when is_binary(host) do
    case Regex.run(~r/\Aehos\.(\d{1,3}(?:-\d{1,3}){3})\.sslip\.io\z/, host) do
      [_, dashed] -> String.replace(dashed, "-", ".")
      nil -> nil
    end
  end

  def sslip_address(_host), do: nil

  # A host written into the CA's name constraints, its admission policy's CEL and the CoreDNS
  # rule's regular expression, and into helm's `--set`: lowercase DNS labels alone, three or more,
  # so no quote, comma, brace or regular expression's character gets in, and no name as broad as a
  # public suffix.
  defp host(host) do
    label = "[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?"
    # The last label starts with a letter, so no IP address reads as a name.
    top = "[a-z]([-a-z0-9]{0,61}[a-z0-9])?"

    if String.length(host) <= 253 and host =~ ~r/\A(#{label}\.){2,}#{top}\z/,
      do: {:ok, host},
      else:
        {:error,
         "--host must be a lowercase DNS name of three labels or more, such as ehos.example.org"}
  end

  defp reachable(target, tunnel) do
    case target.runner.run("kubectl", kubectl_args(target, ["get", "nodes", "-o", "name"])) do
      {_output, 0} ->
        :ok

      {output, status} when is_integer(status) ->
        {:error,
         "The cluster does not answer through the tunnel (exit status #{status}). Open it with " <>
           "#{tunnel}:\n" <> output}

      result ->
        failure("kubectl", result)
    end
  end

  # eh-os D-36: what to do with the SMTP password, decided before anything changes: write the one
  # given, so running again with a new one rotates it; or keep the Secret the cluster holds; or
  # nothing, where the server authenticates with no user. A server whose user has no password
  # anywhere is refused here, before the chart would start EHOS without it.
  defp smtp_password(target, opts) do
    password = Keyword.get(opts, :smtp_password)
    username = get_in(Keyword.get(opts, :mail) || %{}, ["smtp", "username"])

    cond do
      password not in [nil, ""] and username in [nil, ""] ->
        {:error,
         "SMTP_PASSWORD is set, but no SMTP user is: name the user the password belongs to, or " <>
           "unset SMTP_PASSWORD. Nothing was changed."}

      password not in [nil, ""] ->
        # The same password again is kept: nothing rewritten, and nothing restarted for it.
        with {:ok, held} <- held_password(target) do
          if held == Base.encode64(password) do
            target.progress.("Keeping the SMTP password #{@smtp_secret}: it is the one given")
            {:ok, :keep}
          else
            {:ok, {:write, password}}
          end
        end

      username in [nil, ""] ->
        {:ok, :none}

      true ->
        case secret(target, @smtp_secret, "the SMTP password") do
          {:ok, true} ->
            target.progress.("Keeping the SMTP password #{@smtp_secret} the cluster holds")
            {:ok, :keep}

          {:ok, false} ->
            {:error,
             "The SMTP server is to be reached as #{username}, but no password for it is in the " <>
               "cluster: set SMTP_PASSWORD to it. Nothing was changed."}

          error ->
            error
        end
    end
  end

  # The password the Secret holds, base64 as Kubernetes keeps it, or `nil` where there is none.
  # Compared, never printed: a failure says only that it could not be read.
  defp held_password(target) do
    jsonpath = "jsonpath={.data.password}"
    args = kubectl_args(target, ["get", "secret", @smtp_secret, "-n", @namespace, "-o", jsonpath])

    case target.runner.run("kubectl", args) do
      {output, 0} ->
        {:ok, output |> String.split("\n", trim: true) |> List.last()}

      {output, status} when is_integer(status) ->
        if output =~ ~s|(NotFound): secrets "#{@smtp_secret}" not found|,
          do: {:ok, nil},
          else:
            {:error,
             "kubectl could not read the SMTP password #{@smtp_secret} to compare it with " <>
               "SMTP_PASSWORD (exit status #{status}). Nothing was changed."}

      result ->
        failure("kubectl", result)
    end
  end

  defp smtp_written(target, {:write, password}), do: write_smtp_password(target, password)
  defp smtp_written(_target, _kept), do: :ok

  # eh-os D-36: the chart gives the governance plane the password as a variable, read when its pod
  # starts, and Helm sees no change in the pod's template when only the Secret changed: a password
  # written is reached by restarting the governance plane, or the old one would stay in use. The
  # Secret is marked when written and unmarked once the plane restarted, so a run that failed in
  # between restarts it on the next, the password then kept.
  defp restart_for_password(target, {:write, _password}), do: restart_governance(target)

  defp restart_for_password(target, :keep) do
    jsonpath = "jsonpath={.metadata.annotations.#{String.replace(@restart_pending, ".", "\\.")}}"
    args = kubectl_args(target, ["get", "secret", @smtp_secret, "-n", @namespace, "-o", jsonpath])

    case target.runner.run("kubectl", args) do
      {output, 0} -> if output =~ "pending", do: restart_governance(target), else: :ok
      result -> failure("kubectl", result)
    end
  end

  defp restart_for_password(_target, :none), do: :ok

  defp restart_governance(target) do
    target.progress.("Restarting the governance plane, so it sends mail with the new password")
    deployment = "deployment/ehos-governance"

    with :ok <- kubectl(target, ["rollout", "restart", deployment, "-n", @namespace]),
         :ok <-
           kubectl(target, ["rollout", "status", deployment, "-n", @namespace, "--timeout", "10m"]) do
      kubectl(target, [
        "annotate",
        "secret",
        @smtp_secret,
        "-n",
        @namespace,
        @restart_pending <> "-"
      ])
    end
  end

  # The token is written when given, so running again with a new one rotates it; without one,
  # the credential already in the cluster is kept. The user and token, when given, are what Helm
  # pulls a release's chart with too, from the same private registry.
  defp credential(target, opts) do
    token = Keyword.get_lazy(opts, :token, fn -> System.get_env("GHCR_TOKEN") end)

    cond do
      is_binary(token) and String.trim(token) != "" ->
        with {:ok, username} <- username(target, opts),
             :ok <- write_pull_credential(target, @registry, username, String.trim(token)),
             do: {:ok, {username, String.trim(token)}}

      # A release's chart is pulled with the token on every install, while it is private.
      match?(%Source{chart: {:oci, _}}, target.source) ->
        {:error,
         "EHOS's image and chart are in private GHCR packages: set GHCR_TOKEN to a classic " <>
           "GitHub token with read:packages alone (#218); Helm pulls the chart with it on every " <>
           "installation"}

      true ->
        case pull_credential(target) do
          {:ok, true} ->
            target.progress.("Keeping the pull credential #{@pull_credential} the cluster holds")
            {:ok, nil}

          {:ok, false} ->
            {:error,
             "EHOS's image is in a private GHCR package: set GHCR_TOKEN to a classic GitHub " <>
               "token with read:packages alone (#218), at least for the first installation"}

          error ->
            error
        end
    end
  end

  defp username(target, opts) do
    case Keyword.get_lazy(opts, :username, fn -> System.get_env("GHCR_USERNAME") end) do
      name when is_binary(name) and name != "" ->
        {:ok, name}

      _none ->
        gh_login(target.runner)
    end
  end

  # The GitHub CLI's user. The runner merges stderr into the output, and gh may print a notice
  # after the value, such as a new release's: the login is the last line that has a login's form.
  defp gh_login(runner) do
    login =
      case runner.run("gh", ["api", "user", "--jq", ".login"]) do
        {output, 0} ->
          output
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.filter(&(&1 =~ ~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\z/))
          |> List.last()

        _no_cli ->
          nil
      end

    if login,
      do: {:ok, String.trim(login)},
      else: {:error, "Set GHCR_USERNAME to the GitHub user the token belongs to"}
  end

  @doc """
  Installs CloudNativePG, cert-manager and trust-manager, each waited for. One already deployed at
  its pinned chart version, with the same values, is left as it is (#220): reinstalling it pulled
  its chart, applied its CRDs and ran its checks again on every run, for nothing. Then has k3s's
  Traefik keep clients' addresses (`keep_client_addresses/1`).
  """
  @spec prerequisites(t()) :: :ok | {:error, String.t()}
  def prerequisites(%__MODULE__{} = target) do
    Enum.reduce_while(prerequisite_releases(), :ok, fn release, :ok ->
      case prerequisite(target, release) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
    |> case do
      :ok -> keep_client_addresses(target)
      error -> error
    end
  end

  @doc """
  Has k3s's bundled Traefik keep each client's own address (eh-os D-117), so the PROXY protocol
  header it sends the governance plane names the client rather than a node, and the governance
  plane can hold each client to its share of the console's connections. k3s's helm-controller
  applies `#{@traefik_client_addresses}`, a `HelmChartConfig` setting Traefik's Service to
  `externalTrafficPolicy: Local`.

  Nothing is done on a cluster that is not k3s, which has no `HelmChartConfig`, nor where a
  `HelmChartConfig` for Traefik was written by someone else: it is theirs, and is said so. One the
  installer wrote is written whole again on each run. On a server of several nodes, a client that
  enters through a node with no Traefik pod is still that node's address.
  """
  @spec keep_client_addresses(t()) :: :ok | {:error, String.t()}
  def keep_client_addresses(%__MODULE__{} = target) do
    with {:ok, crd} <-
           read_value(target, [
             "get",
             "crd",
             "helmchartconfigs.helm.cattle.io",
             "--ignore-not-found",
             "-o",
             "name"
           ]),
         {:ok, written_by} <-
           read_value(target, [
             "get",
             "helmchartconfig",
             "traefik",
             "-n",
             "kube-system",
             "--ignore-not-found",
             "-o",
             "jsonpath={.metadata.name}={.metadata.labels.app\\.kubernetes\\.io/managed-by}"
           ]) do
      cond do
        crd == "" ->
          :ok

        written_by in ["", "traefik=ehos-installer"] ->
          target.progress.("Keeping clients' addresses at Traefik (#{@traefik_client_addresses})")
          kubectl(target, ["apply", "-f", manifest(@traefik_client_addresses)])

        true ->
          target.progress.(
            "Traefik's HelmChartConfig in kube-system is someone else's: set its Service's " <>
              "externalTrafficPolicy to Local yourself, or the console counts every client as one"
          )

          :ok
      end
    end
  end

  # One line kubectl prints, the last, since the runner merges its warnings in first.
  defp read_value(target, args) do
    case target.runner.run("kubectl", kubectl_args(target, args)) do
      {output, 0} -> {:ok, output |> String.split("\n", trim: true) |> List.last("")}
      result -> failure("kubectl", result)
    end
  end

  @doc false
  # Each prerequisite as Helm knows it: its release, namespace, chart and version, and the values
  # it is installed with, which `helm get values` gives back as they are written here.
  def prerequisite_releases do
    [
      %{
        title: "CloudNativePG",
        release: "cnpg",
        namespace: "cnpg-system",
        chart: @cnpg_chart,
        name: "cloudnative-pg",
        version: @cnpg_version,
        values: %{}
      },
      %{
        title: "cert-manager",
        release: "cert-manager",
        namespace: @cert_manager_namespace,
        chart: @cert_manager_chart,
        name: "cert-manager",
        version: @cert_manager_version,
        # D-62: a certificate's Secret belongs to its Certificate, which an Ingress's belongs to,
        # so a route removed takes its key with it, whoever removes it.
        values: %{"crds" => %{"enabled" => true}, "enableCertificateOwnerRef" => true}
      },
      %{
        title: "trust-manager",
        release: "trust-manager",
        namespace: @cert_manager_namespace,
        chart: @trust_manager_chart,
        name: "trust-manager",
        version: @trust_manager_version,
        values: %{
          "app" => %{"trust" => %{"namespace" => @cert_manager_namespace}},
          "secretTargets" => %{"enabled" => false},
          "defaultPackage" => %{"enabled" => false}
        }
      }
    ]
  end

  defp prerequisite(target, release) do
    if installed?(target, release) do
      # Not installed again, but still waited for, as `helm --wait` did: after a cluster or a
      # server restarts, cert-manager's webhook answers only once its pod is ready, and the CA
      # applied next is checked by it.
      target.progress.("#{release.title} is installed (chart #{release.version}); waiting for it")

      kubectl(target, [
        "wait",
        "--for=condition=Available",
        "deployment",
        "--selector",
        "app.kubernetes.io/instance=#{release.release}",
        "--namespace",
        release.namespace,
        "--timeout=5m"
      ])
    else
      target.progress.("Installing #{release.title} (chart #{release.version})")

      helm(
        target,
        ["upgrade", "--install", release.release, release.chart] ++
          ["--namespace", release.namespace, "--create-namespace"] ++
          Enum.flat_map(set_values(release.values), &["--set", &1]) ++ ["--wait"]
      )
    end
  end

  # Deployed at the pinned version with the same values; anything Helm cannot answer, or answers
  # otherwise, installs it again, which is what every run did before.
  defp installed?(target, release) do
    with {:ok, listed} <-
           helm_json(target, [
             "list",
             "--namespace",
             release.namespace,
             "--filter",
             "^#{release.release}$",
             "--output",
             "json"
           ]),
         [%{"chart" => chart, "status" => "deployed"}] <- listed,
         true <- chart == "#{release.name}-#{release.version}",
         {:ok, values} <-
           helm_json(target, [
             "get",
             "values",
             release.release,
             "--namespace",
             release.namespace,
             "--output",
             "json"
           ]) do
      (values || %{}) == release.values
    else
      _other -> false
    end
  end

  defp helm_json(target, args) do
    kubeconfig = if target.kubeconfig, do: ["--kubeconfig", target.kubeconfig], else: []

    case target.runner.run("helm", args ++ ["--kube-context", target.context | kubeconfig]) do
      {output, 0} -> Jason.decode(output)
      _failed -> :error
    end
  end

  @doc false
  # `--set` arguments for nested values, keys sorted so the arguments do not depend on a map's
  # order.
  def set_values(values, prefix \\ []) do
    values
    |> Enum.sort()
    |> Enum.flat_map(fn
      {key, nested} when is_map(nested) -> set_values(nested, prefix ++ [key])
      {key, value} -> ["#{Enum.join(prefix ++ [key], ".")}=#{value}"]
    end)
  end

  @doc """
  Makes the installation's CA, for the target's host, and waits until it is issued. A cluster
  made before D-62 kept its CA in `ehos-system`, behind namespaced issuers, which go.
  """
  @spec certificate_authority(t()) :: :ok | {:error, String.t()}
  def certificate_authority(%__MODULE__{} = target) do
    target.progress.("Creating the installation's CA for #{target.host} (#{@local_ca})")

    before =
      case ca_certificate(target) do
        {:ok, pem} -> pem
        _none -> nil
      end

    with {:ok, _rendered} <- apply_for_host(target, @local_ca),
         :ok <- wait_for_certificate(target, @cert_manager_namespace, @ca_name),
         {:ok, issued} <- ca_pem(target),
         :ok <- if(current?(issued, target.host), do: :ok, else: renew_ca(target)),
         :ok <- await_current(target, 30) do
      if before && not current?(before, target.host) do
        target.progress.(
          "The CA was issued again, so that it may sign #{target.host} and no IP address; its " <>
            "key is the same. Replace any copy of its old certificate you trusted with the new one"
        )
      end

      kubectl(target, [
        "delete",
        "issuer/#{@ca_name}",
        "issuer/ehos-local-selfsigned",
        "certificate/#{@ca_name}",
        "secret/#{@ca_name}",
        "-n",
        @namespace,
        "--ignore-not-found"
      ])
    end
  end

  # cert-manager issues a CA again when its names change, not when its name constraints do: a CA
  # made before #218, or one whose host was another before `--host` moved it (eh-os D-124), is
  # renewed, as `cmctl renew` does, with the same key and name, so what it signed still verifies.
  # Its Ready condition may still say the old certificate is: what decides is the issued
  # certificate itself, read until it permits the host and excludes every IP address.
  defp renew_ca(target) do
    issuing =
      Jason.encode!(%{
        "status" => %{
          "conditions" => [
            %{
              "type" => "Issuing",
              "status" => "True",
              "reason" => "ManuallyTriggered",
              "message" => "Its name constraints permit its host alone and no IP address"
            }
          ]
        }
      })

    kubectl(target, [
      "patch",
      "certificate/#{@ca_name}",
      "-n",
      @cert_manager_namespace,
      "--subresource=status",
      "--type=merge",
      "-p",
      issuing
    ])
  end

  defp await_current(target, attempts) do
    with {:ok, pem} <- ca_pem(target) do
      cond do
        current?(pem, target.host) ->
          :ok

        attempts > 1 ->
          target.sleep.(2_000)
          await_current(target, attempts - 1)

        true ->
          {:error,
           "The CA #{@ca_name} was not issued again for #{target.host} within a minute: " <>
             "see `kubectl describe certificate #{@ca_name} -n #{@cert_manager_namespace}`"}
      end
    end
  end

  defp ca_pem(target) do
    case ca_certificate(target) do
      {:error, {output, status}} -> failure("kubectl", {output, status})
      result -> result
    end
  end

  @doc """
  Whether a certificate, in PEM, has name constraints that exclude every IPv4 and IPv6 address.
  """
  @spec excludes_every_ip?(String.t()) :: boolean()
  def excludes_every_ip?(pem) do
    with [{:Certificate, der, _}] <- :public_key.pem_decode(pem),
         {:OTPCertificate, tbs, _, _} <- decode_certificate(der),
         {:OTPTBSCertificate, _, _, _, _, _, _, _, _, _, extensions} <- tbs,
         {:Extension, _, _, {:NameConstraints, _permitted, excluded}} <-
           Enum.find(List.wrap(extensions), &match?({:Extension, {2, 5, 29, 30}, _, _}, &1)) do
      ranges = for {:GeneralSubtree, {:iPAddress, range}, _, _} <- List.wrap(excluded), do: range
      <<0::64>> in ranges and <<0::256>> in ranges
    else
      _none -> false
    end
  end

  # The CA as the installation needs it: for its host alone, and no IP address.
  defp current?(pem, host), do: excludes_every_ip?(pem) and permits_only?(pem, host)

  @doc """
  Whether the CA in `pem` permits names under `host` alone: the DNS names its name constraints
  permit are that one host. A CA issued before its host changed permits the old one, and signs
  nothing a client would take for the new one.
  """
  @spec permits_only?(String.t(), String.t()) :: boolean()
  def permits_only?(pem, host) do
    with [{:Certificate, der, _}] <- :public_key.pem_decode(pem),
         {:OTPCertificate, tbs, _, _} <- decode_certificate(der),
         {:OTPTBSCertificate, _, _, _, _, _, _, _, _, _, extensions} <- tbs,
         {:Extension, _, _, {:NameConstraints, permitted, _excluded}} <-
           Enum.find(List.wrap(extensions), &match?({:Extension, {2, 5, 29, 30}, _, _}, &1)) do
      names = for {:GeneralSubtree, {:dNSName, name}, _, _} <- List.wrap(permitted), do: name
      names == [String.to_charlist(host)]
    else
      _none -> false
    end
  end

  # `:public_key` raises on DER that is not a certificate.
  defp decode_certificate(der) do
    :public_key.pkix_decode_cert(der, :otp)
  rescue
    _not_a_certificate -> nil
  end

  @doc """
  Gives pods the console's host and every name under it, through a CoreDNS rule that sends them
  to the ingress (D-45). CoreDNS reads the rule at start, so its pods are rolled out to take it,
  once for each rule: the rule's hash is on their template, and the same rule changes nothing, so
  an upgrade keeps name lookups in the cluster up.
  """
  @spec name_in_cluster(t()) :: :ok | {:error, String.t()}
  # The rule is read from the repository, its path a constant.
  # sobelow_skip ["Traversal.FileModule"]
  def name_in_cluster(%__MODULE__{} = target) do
    target.progress.("Giving pods the name #{target.host} (#{@coredns_custom})")
    coredns = ["-n", "kube-system", "deployment/coredns"]

    # Patching the hash in rolls the pods out after the rule changed, or after a run that applied
    # it and stopped before they took it, and never again while it stays the same.
    with {:ok, rule} <- apply_for_host(target, @coredns_custom),
         hash = :sha256 |> :crypto.hash(rule) |> Base.encode16(case: :lower) |> binary_part(0, 16),
         patch =
           Jason.encode!(%{
             "spec" => %{
               "template" => %{"metadata" => %{"annotations" => %{@coredns_rule => hash}}}
             }
           }),
         :ok <- kubectl(target, ["patch", "--type=merge", "-p", patch | coredns]) do
      kubectl(target, ["rollout", "status", "--timeout=2m" | coredns])
    end
  end

  # Rendered for every host, ehos.localhost included, where it changes nothing: the local
  # cluster, which CI's Cluster job brings up, then runs the rendering a server runs.
  # sobelow_skip ["Traversal.FileModule"]
  defp apply_for_host(target, file) do
    TmpDir.with_tmp_dir("ehos-install", fn dir ->
      path = Path.join(dir, file)
      rendered = file |> manifest() |> File.read!() |> for_host(target.host)
      File.write!(path, rendered)
      with :ok <- kubectl(target, ["apply", "-f", path]), do: {:ok, rendered}
    end)
  end

  @doc """
  Writes `ehos.localhost` as `host` in a manifest: in a regular expression, where its dots are
  escaped once or twice, and as a plain name.

      iex> EhosPlatform.Install.for_host("dnsDomains: [ehos.localhost]", "ehos.1-2-3-4.sslip.io")
      "dnsDomains: [ehos.1-2-3-4.sslip.io]"

      iex> EhosPlatform.Install.for_host(~S"^(.+\\.)?ehos\\.localhost\\.$", "ehos.example.org")
      ~S"^(.+\\.)?ehos\\.example\\.org\\.$"
  """
  @spec for_host(String.t(), String.t()) :: String.t()
  def for_host(contents, host) do
    contents
    |> String.replace(~S"ehos\\.localhost", String.replace(host, ".", ~S"\\."))
    |> String.replace(~S"ehos\.localhost", String.replace(host, ".", ~S"\."))
    |> String.replace(@local_host, host)
  end

  @doc """
  Hands the console's Certificate to the chart in `package`, installed with `values`, when
  cert-manager made it for an Ingress and that chart makes it itself (eh-os D-117). Before D-117
  cert-manager made it from the console's Ingress annotation, owned by that Ingress; since, the
  chart makes it under the same name, and Helm refuses to take over an object it did not make. So
  one Helm did not make is marked as the release's, and freed from the Ingress, whose removal would
  otherwise delete it. Its Secret, and the certificate in it, stay as they are, and the console
  keeps being served while the release is upgraded.

  Nothing is done when there is none, when Helm made it, or when the chart being installed is one
  from before D-117, which still asks for it through the Ingress: handed over then, cert-manager
  would stop keeping it in step with the Ingress, a changed host among it. A chart from before
  D-117 installed over one after makes Helm delete it, and its Secret with it, since cert-manager
  owns a Certificate's Secret here (D-62's `enableCertificateOwnerRef`): the console has no
  certificate until cert-manager issues one again for the Ingress.
  """
  @spec adopt_console_certificate(t(), Path.t(), [String.t()]) :: :ok | {:error, String.t()}
  def adopt_console_certificate(%__MODULE__{} = target, package, values) do
    args =
      kubectl_args(target, [
        "get",
        "certificate",
        @tls_secret,
        "-n",
        @namespace,
        "--ignore-not-found",
        "-o",
        "jsonpath={.metadata.name}={.metadata.labels.app\\.kubernetes\\.io/managed-by}"
      ])

    # The runner merges stderr into the output, where kubectl warns first: the value is last.
    case target.runner.run("kubectl", args) do
      {output, 0} ->
        case output |> String.split("\n", trim: true) |> List.last("") do
          @tls_secret <> "=Helm" -> :ok
          @tls_secret <> "=" <> _other -> hand_over_if_the_chart_makes_it(target, package, values)
          _none -> :ok
        end

      result ->
        failure("kubectl", result)
    end
  end

  # The chart, rendered with the values it is installed with, makes the console's Certificate.
  defp hand_over_if_the_chart_makes_it(target, package, values) do
    case target.runner.run(
           "helm",
           ["template", "ehos", package, "--namespace", @namespace] ++ values
         ) do
      {output, 0} ->
        if makes_console_certificate?(output),
          do: hand_over_console_certificate(target),
          else: :ok

      result ->
        failure("helm", result)
    end
  end

  # The rendered documents, read as YAML rather than matched as text, so their keys' order and
  # quoting do not matter.
  defp makes_console_certificate?(rendered) do
    rendered
    |> YamlElixir.read_all_from_string!()
    |> Enum.any?(fn
      %{"kind" => "Certificate", "metadata" => %{"name" => @tls_secret}} -> true
      _other -> false
    end)
  end

  defp hand_over_console_certificate(target) do
    target.progress.("Handing the console's certificate over to the chart")

    patch = %{
      "metadata" => %{
        "ownerReferences" => nil,
        "labels" => %{"app.kubernetes.io/managed-by" => "Helm"},
        "annotations" => %{
          "meta.helm.sh/release-name" => "ehos",
          "meta.helm.sh/release-namespace" => @namespace
        }
      }
    }

    kubectl(target, [
      "patch",
      "certificate",
      @tls_secret,
      "-n",
      @namespace,
      "--type=merge",
      "-p",
      Jason.encode!(patch)
    ])
  end

  @doc "Waits until cert-manager's Certificate `name` in `namespace` is ready."
  @spec wait_for_certificate(t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def wait_for_certificate(%__MODULE__{} = target, namespace, name) do
    target.progress.("Waiting for the certificate #{namespace}/#{name}")

    kubectl(target, [
      "wait",
      "--for=condition=Ready",
      "certificate/#{name}",
      "-n",
      namespace,
      "--timeout=2m"
    ])
  end

  @doc """
  The certificate of the installation's CA, in PEM, read from the cluster. Its key is never read.
  `{:error, {output, status}}` when kubectl fails, for the caller to explain.
  """
  @spec ca_certificate(t()) ::
          {:ok, String.t()} | {:error, String.t()} | {:error, {String.t(), integer()}}
  def ca_certificate(%__MODULE__{} = target) do
    args =
      kubectl_args(target, [
        "get",
        "secret",
        @ca_name,
        "-n",
        @cert_manager_namespace,
        "-o",
        "jsonpath={.data.ca\\.crt}"
      ])

    # The runner merges stderr into the output, and kubectl prints its warnings before the value,
    # so the value is the last line.
    with {output, 0} <- target.runner.run("kubectl", args),
         {:ok, pem} <-
           output |> String.split("\n", trim: true) |> List.last("") |> Base.decode64(),
         true <- String.starts_with?(pem, "-----BEGIN CERTIFICATE-----") do
      {:ok, pem}
    else
      {output, status} when is_integer(status) -> {:error, {output, status}}
      {:error, :not_found} = result -> failure("kubectl", result)
      _not_a_certificate -> {:error, "The secret #{@ca_name} holds no CA certificate"}
    end
  end

  @doc """
  Whether `ehos-system` holds the pull credential: `{:ok, true}`, `{:ok, false}` when kubectl
  says it is not there or that `ehos-system` is not (#300), and an error when kubectl could not
  say, as when the cluster does not answer. Before, any failure read as none, and environments
  went without it (ehos-tools#174).
  """
  @spec pull_credential(t()) :: {:ok, boolean()} | {:error, String.t()}
  def pull_credential(%__MODULE__{} = target),
    do: secret(target, @pull_credential, "the pull credential")

  defp secret(target, name, what) do
    args = kubectl_args(target, ["get", "secret", name, "-n", @namespace, "-o", "name"])

    case target.runner.run("kubectl", args) do
      {_output, 0} ->
        {:ok, true}

      {output, status} when is_integer(status) ->
        # The Secret's NotFound, or the namespace's on a cluster EHOS was never installed in
        # (#300), is an answer; "the server could not find the requested resource", a proxy's
        # or another server's NotFound, is not.
        if output =~ ~s|(NotFound): secrets "#{name}" not found| or
             output =~ ~s|(NotFound): namespaces "#{@namespace}" not found|,
           do: {:ok, false},
           else:
             {:error,
              "kubectl could not say whether #{@namespace} holds #{what} #{name}:\n" <> output}

      result ->
        failure("kubectl", result)
    end
  end

  @doc """
  Whether `ehos-system` holds the pull credential, reading anything but a clean answer as none.
  Deprecated in its documentation alone, so eh-os, which calls it, still builds with warnings as
  errors against a checkout of this package until it moves to `pull_credential/1` (#174).
  """
  @doc deprecated: "Use pull_credential/1, which says when kubectl could not answer"
  @spec pull_credential?(t()) :: boolean()
  def pull_credential?(%__MODULE__{} = target), do: pull_credential(target) == {:ok, true}

  @doc """
  Writes the pull credential for `registry` into `ehos-system`, replacing one there: a
  `kubernetes.io/dockerconfigjson` Secret, applied from a file only this user reads, which is
  removed after. The token is never an argument of a program, nor in what a failure prints.
  """
  @spec write_pull_credential(t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, String.t()}
  def write_pull_credential(%__MODULE__{} = target, registry, username, token)
      when is_binary(token) and token != "" do
    target.progress.("Writing the pull credential for #{registry} (#{@pull_credential})")
    auth = Base.encode64("#{username}:#{token}")
    config = %{"auths" => %{registry => %{"username" => username, "auth" => auth}}}
    dockerconfigjson = Base.encode64(Jason.encode!(config))

    secret = %{
      "apiVersion" => "v1",
      "kind" => "Secret",
      "type" => "kubernetes.io/dockerconfigjson",
      "metadata" => %{"name" => @pull_credential, "namespace" => @namespace},
      "data" => %{".dockerconfigjson" => dockerconfigjson}
    }

    apply_secret(target, secret, [token, auth, dockerconfigjson], "[the token]")
  end

  @doc """
  Writes the SMTP user's password into `ehos-system` (eh-os D-36), replacing one there: an Opaque
  Secret the chart reads under `password`, applied as the pull credential is. The password is
  never an argument of a program, nor in what a failure prints.
  """
  @spec write_smtp_password(t(), String.t()) :: :ok | {:error, String.t()}
  def write_smtp_password(%__MODULE__{} = target, password)
      when is_binary(password) and password != "" do
    target.progress.("Writing the SMTP password (#{@smtp_secret})")
    encoded = Base.encode64(password)

    secret = %{
      "apiVersion" => "v1",
      "kind" => "Secret",
      "type" => "Opaque",
      "metadata" => %{
        "name" => @smtp_secret,
        "namespace" => @namespace,
        "annotations" => %{@restart_pending => "pending"}
      },
      "data" => %{"password" => encoded}
    }

    apply_secret(target, secret, [password, encoded], "[the password]")
  end

  # A Secret, with EHOS's namespace in case it is not there yet, applied from a file only this user
  # reads, which is removed after; what it holds, `hidden`, is replaced in what a failure prints.
  # sobelow_skip ["Traversal.FileModule"]
  defp apply_secret(target, secret, hidden, placeholder) do
    name = secret["metadata"]["name"]

    namespace = %{
      "apiVersion" => "v1",
      "kind" => "Namespace",
      "metadata" => %{"name" => @namespace}
    }

    TmpDir.with_tmp_dir(name, fn dir ->
      path = Path.join(dir, "secret.json")
      list = %{"apiVersion" => "v1", "kind" => "List", "items" => [namespace, secret]}
      # Made exclusively, so nothing already at the path, a link included, is written through.
      :ok = File.write(path, Jason.encode!(list), [:exclusive])
      File.chmod!(path, 0o600)

      # Server-side: a client-side apply keeps the whole object, the value in it, in the
      # `last-applied-configuration` annotation, a second copy anyone who may read the Secret's
      # metadata could read.
      try do
        case kubectl(target, ["apply", "--server-side", "--force-conflicts", "-f", path]) do
          # One written before by a client-side apply keeps that copy until it is removed.
          :ok ->
            kubectl(target, [
              "annotate",
              "secret",
              name,
              "-n",
              @namespace,
              "kubectl.kubernetes.io/last-applied-configuration-"
            ])

          {:error, message} ->
            {:error, Enum.reduce(hidden, message, &String.replace(&2, &1, placeholder))}
        end
      after
        _ = File.rm(path)
      end
    end)
  end

  @doc """
  Installs or upgrades the chart, packaged as a distribution is, and waits until EHOS is ready and
  the console's certificate is issued. A console Certificate cert-manager made for the console's
  Ingress is handed over to a chart that makes it itself first (`adopt_console_certificate/3`).

  ## Options

    * `:repository` and `:digest` — the image, always by digest (required).
    * `:ca_file` — the CA's certificate, which environments are given (D-59) (required).
    * `:allowed_image_prefixes` — where a pod in an environment may pull from (D-55).
    * `:pull_credential?` — whether `ehos-system` holds the pull credential, which is then given
      to environments (D-55).
    * `:own_pull_credential?` — whether EHOS's own pods pull with it too, as on a server, whose
      EHOS image comes from the private registry; the local cluster's comes from its own.
    * `:installation` — what the installation is, the chart's `installation` value (D-90): a map
      of `name`, `provider`, `region` and `size`, each a line of text. None says nothing.
    * `:installed` — what is installed, `version`, `image` and `chart`, the release's `installed`
      value, which nothing in the chart reads and `installed/1` reads back (eh-os D-92). None
      writes none.
    * `:registry_auth` — `{username, token}` for the registry a release's chart is pulled from,
      given to Helm in a registry configuration only this user reads, removed after, never on a
      command line. None leaves Helm its own login, if any.
  """
  @spec chart(t(), keyword()) :: :ok | {:error, String.t()}
  def chart(%__MODULE__{} = target, opts) do
    repository = Keyword.fetch!(opts, :repository)
    digest = Keyword.fetch!(opts, :digest)
    ca_file = Keyword.fetch!(opts, :ca_file)
    prefixes = Keyword.get(opts, :allowed_image_prefixes, ["ghcr.io/empoweredhouse/"])
    pull? = Keyword.get(opts, :pull_credential?, false)

    # D-90: what the installation is, for its page. JSON, since a size such as `4 OCPUs, 24 GB`
    # holds a comma, which `--set` would split on.
    described =
      case Keyword.get(opts, :installation, %{}) do
        empty when map_size(empty) == 0 -> []
        installation -> ["--set-json", "installation=#{Jason.encode!(installation)}"]
      end

    # D-92: what runs, for `ehosctl upgrade` to read back through the kubeconfig.
    recorded =
      case Keyword.get(opts, :installed) do
        nil -> []
        installed -> ["--set-json", "installed=#{Jason.encode!(installed)}"]
      end

    # eh-os D-113: how long a sign-in to an application lasts, which the chart checks; JSON, as
    # the installation's description is.
    sign_in =
      case Keyword.get(opts, :sign_in) do
        limits when is_map(limits) and map_size(limits) > 0 ->
          ["--set-json", "governance.signIn=#{Jason.encode!(limits)}"]

        _none ->
          []
      end

    # eh-os D-105: whether a promotion to production needs a second person; none, the chart's.
    four_eyes =
      case Keyword.get(opts, :four_eyes) do
        given when is_boolean(given) -> ["--set-json", "governance.promotion.fourEyes=#{given}"]
        nil -> []
      end

    # eh-os D-36: the SMTP server, and the Secret its password is in when it authenticates; JSON,
    # as the sign-in limits are. None: the chart's default, which sends no mail.
    mail =
      case Keyword.get(opts, :mail) do
        %{"smtp" => %{} = smtp} = mail ->
          smtp =
            if smtp["username"] not in [nil, ""],
              do:
                Map.put(smtp, "password", %{
                  "secretName" => @smtp_secret,
                  "secretKey" => "password"
                }),
              else: smtp

          ["--set-json", "governance.mail=#{Jason.encode!(%{mail | "smtp" => smtp})}"]

        _none ->
          []
      end

    own =
      if Keyword.get(opts, :own_pull_credential?, false),
        do: ["--set", "imagePullSecrets[0].name=#{@pull_credential}"],
        else: []

    values =
      chart_values(target, repository, digest, ca_file, prefixes, pull?) ++
        described ++ recorded ++ sign_in ++ four_eyes ++ mail ++ own

    installed =
      TmpDir.with_tmp_dir("ehos-cluster", fn dir ->
        with {:ok, package} <- chart_reference(target, dir, opts[:registry_auth]),
             :ok <- adopt_console_certificate(target, package, values) do
          target.progress.("Installing EHOS and waiting until it is ready")

          helm(
            target,
            [
              "upgrade",
              "--install",
              "ehos",
              package,
              "--namespace",
              @namespace,
              "--create-namespace",
              "--wait",
              "--timeout",
              "10m"
            ] ++ values
          )
        end
      end)

    with :ok <- installed, do: wait_for_certificate(target, @namespace, @tls_secret)
  end

  defp chart_values(target, repository, digest, ca_file, prefixes, pull?) do
    [
      "--set",
      "image.repository=#{repository}",
      "--set",
      "image.digest=#{digest}",
      "--set",
      "governance.host=#{target.host}",
      # D-45: cert-manager issues the console's certificate from the installation's CA. The
      # chart's defaults for the console's URL, https on 443, are what the ingress serves.
      "--set",
      "governance.ingress.tls.secretName=#{@tls_secret}",
      "--set",
      "governance.ingress.annotations.cert-manager\\.io/cluster-issuer=#{@ca_name}",
      # D-62: every application's address gets a certificate of its own from the same CA.
      "--set",
      "environments.ingress.annotations.cert-manager\\.io/cluster-issuer=#{@ca_name}",
      "--set",
      "environments.ingress.tls=true",
      # D-55: where a pod in an environment may pull its image from.
      "--set",
      "environments.allowedImagePrefixes={#{Enum.join(prefixes, ",")}}",
      # D-59: the installation's CA certifies the console's host, so environments are given it.
      "--set-file",
      "environments.caCertificate=#{ca_file}"
    ] ++
      if(pull?, do: ["--set", "environments.imagePullSecret=#{@pull_credential}"], else: [])
  end

  # A release's chart is installed by its digest, which Helm checks; a checkout's is packaged first.
  # A release's chart is pulled by its digest, which Helm checks, into the private directory, and
  # installed from there; a checkout's is packaged first.
  defp chart_reference(
         %__MODULE__{source: %Source{chart: {:oci, reference}}} = target,
         dir,
         auth
       ),
       do: pull(target, reference, dir, auth)

  defp chart_reference(%__MODULE__{source: %Source{chart: {:directory, chart}}} = target, dir, _),
    do: package(target.runner, chart, dir)

  # The chart is in GHCR, private while EHOS's packages are (eh-os D-92). Helm is given the
  # credential the image is pulled with, in a registry configuration in the Docker format, only
  # this user reads, for the pull alone: it is removed as soon as the chart is here, not kept for
  # the install's ten minutes. Without one, Helm's own login is used.
  # sobelow_skip ["Traversal.FileModule"]
  defp pull(target, reference, dir, auth) do
    registry = Path.join(dir, "registry.json")
    charts = Path.join(dir, "chart")

    with :ok <- File.mkdir(charts) |> or_cannot_write(charts),
         {:ok, args} <- registry_config(registry, auth) do
      target.progress.("Pulling EHOS's chart by its digest")
      pulled = target.runner.run("helm", ["pull", reference, "--destination", charts | args])
      File.rm(registry)

      case {pulled, Path.wildcard(Path.join(charts, "*.tgz"))} do
        {{_output, 0}, [package]} -> {:ok, package}
        {{_output, 0}, _none} -> {:error, "`helm pull` saved no single chart in #{charts}"}
        {result, _} -> refused(failure("helm", result), auth)
      end
    end
  end

  defp or_cannot_write(:ok, _path), do: :ok

  defp or_cannot_write({:error, reason}, path),
    do: {:error, "#{path} cannot be made: #{:file.format_error(reason)}"}

  defp registry_config(_path, nil), do: {:ok, []}

  defp registry_config(path, {username, token}) do
    auth = Base.encode64("#{username}:#{token}")
    config = Jason.encode!(%{"auths" => %{@registry => %{"auth" => auth}}})

    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, device} ->
        written =
          try do
            with :ok <- File.chmod(path, 0o600), do: IO.binwrite(device, config)
          after
            File.close(device)
          end

        if written == :ok,
          do: {:ok, ["--registry-config", path]},
          else: cannot_write_registry(written)

      error ->
        cannot_write_registry(error)
    end
  end

  defp cannot_write_registry({:error, reason}),
    do: {:error, "The registry configuration cannot be written: #{:file.format_error(reason)}"}

  # A chart GHCR would not give says how to give it the credential, rather than Helm's 403 alone.
  defp refused({:error, message} = error, auth) do
    cond do
      not (message =~ ~r/response status code 40[13]|: (unauthorized|denied):/i) ->
        error

      auth ->
        {:error,
         message <>
           "\nGHCR refused EHOS's chart to GHCR_TOKEN: it needs read:packages, and must not " <>
           "have expired"}

      true ->
        {:error,
         message <>
           "\nEHOS's chart is in a private GHCR package: set GHCR_TOKEN to a classic GitHub " <>
           "token with read:packages alone (#218)"}
    end
  end

  defp package(runner, chart, dir) do
    case runner.run("helm", ["package", chart, "--destination", dir]) do
      {output, 0} ->
        case Regex.run(~r/saved it to: (\S+\.tgz)/, output, capture: :all_but_first) do
          [path] -> {:ok, path}
          nil -> {:error, "`helm package` did not say where it saved the chart:\n" <> output}
        end

      result ->
        failure("helm", result)
    end
  end

  @doc "Runs `kubectl` with `args` against the target. `:ok`, or the error with its output."
  @spec kubectl(t(), [String.t()]) :: :ok | {:error, String.t()}
  def kubectl(%__MODULE__{} = target, args),
    do: run(target.runner, "kubectl", kubectl_args(target, args))

  @doc "The arguments that point `kubectl` at the target, before `args`."
  @spec kubectl_args(t(), [String.t()]) :: [String.t()]
  def kubectl_args(%__MODULE__{kubeconfig: nil, context: context}, args),
    do: ["--context", context | args]

  def kubectl_args(%__MODULE__{kubeconfig: kubeconfig, context: context}, args),
    do: ["--kubeconfig", kubeconfig, "--context", context | args]

  defp helm(target, args) do
    kubeconfig = if target.kubeconfig, do: ["--kubeconfig", target.kubeconfig], else: []
    run(target.runner, "helm", args ++ ["--kube-context", target.context | kubeconfig])
  end

  defp run(runner, program, args) do
    case runner.run(program, args) do
      {_output, 0} -> :ok
      result -> failure(program, result)
    end
  end

  defp failure(program, {:error, :not_found}),
    do:
      {:error,
       "`#{program}` is not installed, or not at the version EHOS pins: `ehosctl doctor` says what is missing (`mix ehos.doctor` in eh-os)"}

  defp failure(program, {output, status}),
    do: {:error, "`#{program}` failed with exit status #{status}:\n" <> output}

  @doc "The path of one of the manifests the installer applies, in this package's `priv/`."
  @spec manifest(String.t()) :: Path.t()
  def manifest(file),
    do: Path.join([Application.app_dir(:ehos_platform), "priv", "manifests", file])
end
