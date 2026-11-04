defmodule Ehosctl.Credential do
  @moduledoc """
  `ehosctl credential <application> [--env E]`: a credential for an application, for a script or
  `curl` to present as `Authorization: Bearer …`.

  It is the one `ehosctl call` presents: renewed from the sign-in with the application's address
  as `resource` (eh-os D-89), and kept until it expires, so asking again within its ten minutes
  gives the same one. The refresh token is never printed. Where none of the person's roles grants
  anything, EHOS refuses it (`no_capability`), which exits 3.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.Credentials
  alias Ehosctl.Output

  @impl Ehosctl.Command
  def name, do: :credential

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def spec,
    do: [
      about:
        "Print a credential for an application. A script or curl can send it to the " <>
          "application.",
      args: [
        application: [
          value_name: "APPLICATION",
          required: true,
          help: "The application, as `ehosctl apps` shows it."
        ]
      ],
      options: [env: env_option()],
      flags: Output.json_flag()
    ]

  @doc "The `--env` option, which `credential` and `call` take."
  @spec env_option() :: keyword()
  def env_option,
    do: [
      long: "--env",
      value_name: "ENVIRONMENT",
      help: "The environment. If you hold a role in only one environment, you can leave it out."
    ]

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)

    with {:ok, applications} <- Api.applications(installation, opts),
         {:ok, entry} <- Api.choose(applications, parsed.args.application, parsed.options.env),
         {:ok, credential} <- Credentials.fetch(installation, entry["address"], opts),
         true <-
           Output.printable?(credential) ||
             {:error, :failed,
              "EHOS issued a credential with characters that ehosctl does not print."} do
      {:ok,
       %{
         text: credential,
         json: %{
           application: entry["application"],
           environment: entry["environment"],
           audience: entry["audience"],
           address: entry["address"],
           credential: credential
         }
       }}
    end
  end
end
