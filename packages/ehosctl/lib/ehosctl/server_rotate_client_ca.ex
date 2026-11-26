defmodule Ehosctl.ServerRotateClientCa do
  @moduledoc """
  `ehosctl server rotate-client-ca`: ends the admin certificate of k3s that the installation
  administrators of an installation made before eh-os D-199 copied, by a new client CA of the
  cluster and a new server token of k3s, with `EhosPlatform.Server.ClientCa`. It is the last step
  of moving such an installation, after each administrator has access of their own and the shared
  key is gone, which it checks before a first start.

  It runs under `ehosctl server` (`c:Ehosctl.Command.mounted/0`), on the platform plane: it works
  over SSH with the key this workstation logs in with, and reads the server's address from the
  installation's state, so it needs the state passphrase. The rotation runs as a process on the
  server, which goes on when SSH drops; run again, the command follows it, or finishes or undoes
  a rotation that stopped.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.PlatformReport

  @impl Ehosctl.Command
  def name, do: :"rotate-client-ca"

  @impl Ehosctl.Command
  def plane, do: :platform

  @impl Ehosctl.Command
  def group, do: :installation

  @impl Ehosctl.Command
  def summary, do: "Replace the client CA of the cluster, to end each copied admin certificate."

  @impl Ehosctl.Command
  def spec do
    [
      about:
        "Replace the client CA of the cluster and the server token of k3s. The certificates " <>
          "of the old client CA stop working, also each copy of the admin certificate of k3s. " <>
          "EHOS stops while the rotation runs.",
      options: [
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
            "The private key to log in with. By default the key that `up` recorded, else " <>
              "~/.ssh/ehos_oci."
        ]
      ]
    ]
  end

  @doc """
  Runs the rotation through `Ehosctl.ServerAdministrators`. `opts` are what `Ehosctl.Server`
  takes.
  """
  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], parsed, opts) do
    with {:ok, name} <- Ehosctl.Server.installation(parsed.options[:installation], opts),
         {:ok, platform_opts} <- Ehosctl.Server.platform_opts(name, parsed, opts) do
      platform_opts
      |> Ehosctl.ServerAdministrators.current().rotate_client_ca()
      |> reported()
    end
  end

  defp reported({:ok, report}), do: {:ok, %{text: PlatformReport.text(report), json: nil}}
  defp reported({:error, message}), do: {:error, :failed, PlatformReport.failure(message)}
end
