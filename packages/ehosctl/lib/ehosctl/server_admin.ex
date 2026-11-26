defmodule Ehosctl.ServerAdmin do
  @moduledoc """
  `ehosctl server admin add | remove | list`: the installation administrators of a server, each
  with an SSH key of their own and a ClusterRoleBinding of their own (eh-os D-199), with
  `EhosPlatform.Server.Administrators`.

  It runs under `ehosctl server` (`c:Ehosctl.Command.mounted/0`), on the platform plane: it works
  over SSH with the key this workstation logs in with, reads the server's address from the
  installation's state, so it needs the state passphrase, and needs no cloud credential. The
  installation is chosen as for every `ehosctl server` command (`Ehosctl.Server.installation/3`).

  On an installation made before eh-os D-199, every administrator holds the shared key: `list`
  shows it unnamed, `add` names it `shared` and adds a person beside it, and `remove shared`
  removes it once a person has access of their own.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.PlatformReport

  @impl Ehosctl.Command
  def name, do: :admin

  @impl Ehosctl.Command
  def plane, do: :platform

  @impl Ehosctl.Command
  def group, do: :installation

  @impl Ehosctl.Command
  def summary, do: "Add, remove and list the installation administrators of the server."

  @where [
    installation: [
      long: "--installation",
      value_name: "NAME",
      help:
        "The installation of the server. By default EHOSCTL_INSTALLATION, else the current " <>
          "installation, else trial."
    ],
    ssh_key: [
      long: "--ssh-key",
      value_name: "PATH",
      help:
        "The private key to log in with. ehosctl keeps its .pub on the server. By default the " <>
          "key that `up` recorded, else ~/.ssh/ehos_oci."
    ]
  ]

  @name [
    value_name: "NAME",
    required: true,
    help:
      "The name of the installation administrator: 1 to 31 lowercase letters, digits and " <>
        "hyphens, that starts with a letter."
  ]

  @impl Ehosctl.Command
  def spec do
    [
      about:
        "Add, remove and list the installation administrators of the server. Each one logs in " <>
          "with an SSH key of their own and has a ClusterRoleBinding of their own. ehosctl " <>
          "changes the server over SSH. It needs the state passphrase, and no cloud credential.",
      subcommands: [
        add: [
          name: "add",
          about:
            "Add an installation administrator: a line with their public key in " <>
              "authorized_keys, then a ClusterRoleBinding to cluster-admin.",
          args: [name: @name],
          options:
            [
              public_key: [
                long: "--public-key",
                value_name: "FILE",
                required: true,
                help:
                  "The .pub file of the new key of the person: one ssh-ed25519 or " <>
                    "ecdsa-sha2-nistp256 key, with no options."
              ]
            ] ++ @where
        ],
        remove: [
          name: "remove",
          about:
            "Remove an installation administrator, or the shared key: their line in " <>
              "authorized_keys, then their user from each binding. ehosctl refuses to remove the last " <>
              "one. An SSH session that is open stays open.",
          args: [
            name:
              Keyword.put(@name, :help, "The name of the installation administrator, or shared.")
          ],
          options: @where
        ],
        list: [
          name: "list",
          about:
            "List the installation administrators, each key in authorized_keys that names " <>
              "nobody, each other subject bound to cluster-admin, and the certificate signing " <>
              "requests.",
          options: @where
        ]
      ]
    ]
  end

  @doc """
  Runs `add`, `remove` or `list` through `Ehosctl.ServerAdministrators`. `opts` are what
  `Ehosctl.Server` takes.
  """
  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([subcommand], parsed, opts) do
    administrators = Ehosctl.ServerAdministrators.current()

    with {:ok, name} <- Ehosctl.Server.installation(parsed.options[:installation], opts),
         {:ok, platform_opts} <- Ehosctl.Server.platform_opts(name, parsed, opts) do
      subcommand
      |> run(administrators, parsed, platform_opts)
      |> reported()
    end
  end

  defp run(:add, administrators, parsed, platform_opts),
    do:
      administrators.add(
        parsed.args.name,
        Path.expand(parsed.options.public_key),
        platform_opts
      )

  defp run(:remove, administrators, parsed, platform_opts),
    do: administrators.remove(parsed.args.name, platform_opts)

  defp run(:list, administrators, _parsed, platform_opts), do: administrators.list(platform_opts)

  defp reported({:ok, report}), do: {:ok, %{text: PlatformReport.text(report), json: nil}}
  defp reported({:error, message}), do: {:error, :failed, PlatformReport.failure(message)}
end
