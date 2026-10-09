defmodule Ehosctl.Whoami do
  @moduledoc """
  `ehosctl whoami`: who is signed in to the installation, and until when (eh-os D-89).

  It says what `ehosctl login` kept, and asks EHOS nothing: the person is the ID token's `email`,
  else its `sub`, and the sign-in lasts until the earlier of its seven days and three days after
  its last renewal (`Ehosctl.Credentials.until/2`). EHOS may end it sooner, which the next
  renewal finds.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Credentials
  alias Ehosctl.Output
  alias Ehosctl.TokenStore

  @impl Ehosctl.Command
  def name, do: :whoami

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def spec,
    do: [about: "Say who you are signed in as, and until when.", flags: Output.json_flag()]

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], _parsed, opts) do
    {name, installation} = Keyword.fetch!(opts, :installation)
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)
    dir = Keyword.get_lazy(opts, :state_dir, fn -> TokenStore.dir(env) end)
    url = installation["url"]

    with {:ok, sign_in} <- Credentials.signed_in(installation),
         {:ok, session} <- session(dir, name, url) do
      until = Credentials.until(sign_in, session)

      if DateTime.after?(until, DateTime.utc_now()) do
        person = sign_in["email"] || sign_in["subject"]

        {:ok,
         %{
           text: "You are #{person}, signed in to #{name} (#{url}) until #{Output.date(until)}.",
           json: %{
             installation: name,
             url: url,
             subject: sign_in["subject"],
             email: sign_in["email"],
             signed_in_at: sign_in["signed_in_at"],
             until: DateTime.to_iso8601(until)
           }
         }}
      else
        {:error, :not_signed_in, "Your sign-in has expired. Run `ehosctl login`."}
      end
    end
  end

  defp session(dir, name, url) do
    case TokenStore.read(dir, name) do
      {:ok, %{url: ^url} = session} -> {:ok, session}
      {:error, _kind, _message} = error -> error
      _none -> {:error, :not_signed_in, "You are not signed in. Run `ehosctl login`."}
    end
  end
end
