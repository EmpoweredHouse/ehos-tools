defmodule Ehosctl.SignInCase do
  @moduledoc """
  What the tests of the commands that talk to EHOS share: a fake EHOS (`Ehosctl.FakeProvider`),
  a configuration and a state directory of their own, `Ehosctl.Case.ehosctl/2` to run a command
  line, and helpers that answer EHOS's API and read back what was sent to it. The keychain is
  `Ehosctl.Case`'s fake.

  Not async: `Ehosctl.Case.ehosctl/2` captures stderr, which is one device for every process, so
  tests that ran beside each other would read each other's errors.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use Ehosctl.Case, async: false

      import Ehosctl.SignInCase

      alias Ehosctl.Config
      alias Ehosctl.FakeKeychain
      alias Ehosctl.FakeProvider
      alias Ehosctl.TokenStore

      @moduletag :tmp_dir
    end
  end

  setup %{tmp_dir: tmp_dir} do
    provider = Ehosctl.FakeProvider.start()
    Ehosctl.Case.stub_browser(Ehosctl.FakeProvider.browser(provider))

    opts = [
      config_dir: Path.join(tmp_dir, "config"),
      state_dir: Path.join(tmp_dir, "state"),
      timeout: 5_000
    ]

    %{provider: provider, opts: opts}
  end

  @doc "Signs in to the fake provider as `name`, and returns the command's stdout."
  @spec login!(Ehosctl.FakeProvider.t(), keyword(), [String.t()]) :: String.t()
  def login!(provider, opts, extra \\ []) do
    {0, stdout, _stderr} = Ehosctl.Case.ehosctl(["login", provider.issuer | extra], opts)
    stdout
  end

  @doc "Answers `method` at `path` of the fake EHOS's API with `status` and `body`, whatever is sent."
  @spec api(Ehosctl.FakeProvider.t(), String.t(), String.t(), pos_integer(), term()) :: :ok
  def api(provider, method, path, status, body),
    do: Ehosctl.FakeProvider.stub_api(provider, method, path, fn _request -> {status, body} end)

  @doc """
  The requests sent to the fake EHOS's API as `key`, `"<METHOD> <path>"`, oldest first, each with
  its JSON body decoded.
  """
  @spec json_requests(Ehosctl.FakeProvider.t(), String.t()) :: [map()]
  def json_requests(provider, key) do
    for request <- Ehosctl.FakeProvider.requests(provider, key),
        do: %{request | body: JSON.decode!(request.body)}
  end

  @doc "A request to `path` with no query and `body` as JSON, as `json_requests/2` reads one back."
  @spec json_request(String.t(), term()) :: map()
  def json_request(path, body),
    do: %{path: path, query: %{}, body: body, content_type: "application/json"}
end
