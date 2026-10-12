defmodule Ehosctl.Install do
  @moduledoc """
  `ehosctl install`: installs EHOS, by version, on the server under an installation (eh-os D-79,
  D-92), with `EhosPlatform.Install` run through `Ehosctl.PlatformRunner` at the tool versions EHOS
  is tested with (T-13), through the kubeconfig `ehosctl server tunnel` wrote.

  The version is a release's, the newest unless `--version` names another, and its `release.json`
  names the image and the chart, each by digest (`Ehosctl.EhosRelease`): nobody copies a digest.
  What it installs is recorded in the Helm release, and read back before anything is changed:

    * nothing installed: EHOS is installed;
    * the same version, image and chart: it is installed again, which changes nothing in place;
    * another version, the same version with other digests, or an EHOS whose version cannot be
      read, as `mix ehos.install` leaves it: refused, since moving it is `upgrade`'s (eh-os Stage
      13, step 6).

  The registry credential is `GHCR_TOKEN`, a classic token with `read:packages` alone: the cluster
  keeps it for the image after the first install, and Helm pulls the chart with it while EHOS's
  packages are private. Once EHOS runs, the installation is put in `config.json`
  under its name, with the console's address and the installation's CA, so `ehosctl login
  --installation <name>` needs no `EHOSCTL_CA_FILE` (T-13, T-14).
  """

  @behaviour Ehosctl.Command

  alias EhosPlatform.Install, as: Platform
  alias EhosPlatform.Source
  alias Ehosctl.Config
  alias Ehosctl.EhosRelease
  alias Ehosctl.Refusal

  @image ~r/\Aghcr\.io\/empoweredhouse\/ehos@(sha256:[0-9a-f]{64})\z/
  @chart ~r/\Aoci:\/\/ghcr\.io\/empoweredhouse\/charts\/ehos@sha256:[0-9a-f]{64}\z/

  @impl Ehosctl.Command
  def name, do: :install

  @impl Ehosctl.Command
  def plane, do: :platform

  @impl Ehosctl.Command
  def spec do
    [
      about:
        "Install EHOS, by version, on the server under an installation, through its tunnel, " <>
          "with your kubeconfig and GHCR_TOKEN.",
      options: [
        installation: [
          long: "--installation",
          value_name: "NAME",
          help:
            "The installation whose server this is, instead of EHOSCTL_INSTALLATION, the " <>
              "current one, or trial."
        ],
        version: [
          long: "--version",
          value_name: "V",
          help: "The EHOS release to install; the newest by default."
        ],
        host: [
          long: "--host",
          value_name: "HOST",
          help:
            "The console's host, instead of ehos.<address>.sslip.io from the tunnel's address."
        ]
      ]
    ]
  end

  @doc """
  Installs. `opts` may name, for tests, `:install` (the module that does the work,
  `EhosPlatform.Install` by default), `:home` (`~/.ehos`), `:env`, `:config_dir`, `:progress`,
  `:runner`, and `Ehosctl.GitHub`'s options.
  """
  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], parsed, opts) do
    install = Keyword.get(opts, :install, Platform)
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)
    home = Keyword.get(opts, :home, "~/.ehos")

    with {:ok, name} <- Ehosctl.Server.installation(parsed.options[:installation], opts),
         base = [
           name: name,
           home: home,
           runner: Keyword.get(opts, :runner, Ehosctl.PlatformRunner),
           server_command: "ehosctl server"
         ],
         {:ok, running} <- platform(install.installed(base)),
         {:ok, wanted} <- release(parsed.options[:version], opts),
         :ok <- may_install(running, wanted, name),
         {:ok, message} <-
           platform(
             install.server(
               base ++
                 [
                   source: %Source{chart: {:oci, wanted["chart"]}, modules: nil},
                   digest: wanted["digest"],
                   installed: Map.take(wanted, ["version", "image", "chart"]),
                   host: parsed.options[:host],
                   token: env["GHCR_TOKEN"],
                   username: env["GHCR_USERNAME"],
                   progress: Keyword.get(opts, :progress, &progress/1)
                 ]
             )
           ) do
      {:ok, %{text: message <> "\n" <> signed_in(name, home, opts), json: nil}}
    end
  end

  # The release's image and chart, each by digest, as an install takes them.
  defp release(version, opts) do
    with {:ok, release, described} <- EhosRelease.find(version, opts) do
      with %{"version" => version, "image" => image, "chart" => chart}
           when is_binary(image) and
                  is_binary(chart) <-
             described || %{},
           [_image, digest] <- Regex.run(@image, image),
           true <- chart =~ @chart do
        {:ok, %{"version" => version, "image" => image, "chart" => chart, "digest" => digest}}
      else
        _unnamed ->
          {:error, :failed,
           "#{release.tag} names no image and chart of EHOS's by digest to install; take a " <>
             "later release with --version."}
      end
    end
  end

  defp may_install(:none, _wanted, _name), do: :ok

  defp may_install(%{"version" => v} = running, %{"version" => v} = wanted, name) do
    if running["image"] == wanted["image"] and running["chart"] == wanted["chart"],
      do: :ok,
      else:
        {:error, :failed,
         "#{name} runs EHOS #{Refusal.shown(v)} as #{Refusal.shown(running["image"])}, from " <>
           "#{Refusal.shown(running["chart"])}, but its release now names #{wanted["image"]}, " <>
           "from #{wanted["chart"]}. Nothing was changed."}
  end

  defp may_install(%{"version" => running}, %{"version" => wanted}, name),
    do:
      {:error, :invalid,
       "#{name} runs EHOS #{Refusal.shown(running)}; moving it to #{Refusal.shown(wanted)} is " <>
         "not an install, and `ehosctl upgrade` will do it. Nothing was changed."}

  defp may_install(:unknown, _wanted, name),
    do:
      {:error, :invalid,
       "#{name} runs an EHOS whose version ehosctl cannot read from the cluster, as " <>
         "`mix ehos.install` leaves it; until `ehosctl upgrade` can move it, install it again " <>
         "with `mix ehos.install`. Nothing was changed."}

  # The installation in `config.json`, for `login` (T-13, T-14): what `EhosPlatform.Install`
  # wrote beside the installation says its host and its CA. A failure here leaves EHOS running,
  # and says how to sign in without it.
  defp signed_in(name, home, opts) do
    dir = home |> Path.expand() |> Path.join(name)
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)
    config_dir = Keyword.get_lazy(opts, :config_dir, fn -> Config.dir(env) end)
    ca_file = Path.join(dir, "ca.crt")

    host = installed_host(dir)
    url = if host, do: "https://#{host}", else: "https://<the console's host>"

    with true <- host != nil,
         {:ok, pem} when is_binary(pem) <-
           Ehosctl.TLS.ca_file_pem(%{"EHOSCTL_CA_FILE" => ca_file}),
         {:ok, config} <- Config.read(config_dir),
         before = config.installations[name],
         config = config |> Config.put(name, url) |> Config.put_ca(name, pem),
         :ok <- Config.write(config, config_dir) do
      replaced(before, name, url) <>
        "Sign in with `ehosctl login --installation #{name}`: it trusts the installation's CA."
    else
      _not_kept ->
        "Sign in with `EHOSCTL_CA_FILE=#{ca_file} ehosctl login --installation #{name} " <>
          "#{url}`: ehosctl could not keep the installation in its configuration."
    end
  end

  # An installation of that name elsewhere is now this one, which the person should know: their
  # commands to it go here from now on.
  defp replaced(%{"url" => old}, name, url) when old != url,
    do: "The installation #{name} was at #{Ehosctl.Refusal.shown(old)}; it is #{url} now.\n"

  defp replaced(_before, _name, _url), do: ""

  defp installed_host(dir) do
    with {:ok, contents} <- File.read(Path.join(dir, "install.json")),
         {:ok, %{"host" => host}} when is_binary(host) <- JSON.decode(contents),
         true <- Ehosctl.Output.printable?(host) do
      host
    else
      _unread -> nil
    end
  end

  defp platform({:ok, result}), do: {:ok, result}
  defp platform({:error, message}), do: {:error, :failed, message}

  defp progress(line), do: IO.puts(:stderr, "==> " <> line)
end
