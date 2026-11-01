defmodule Ehosctl.ConventionsTest do
  @moduledoc """
  ehosctl held to T-20 by the repository's `EhosTools.ConventionsCase`: only a behaviour's
  implementation reaches a program, the network, the environment, the home directory, the
  terminal, the clock or a wait.
  """

  use EhosTools.ConventionsCase,
    async: true,
    app: :ehosctl,
    # Runs while Mix compiles ehosctl, before any configuration chooses an implementation: it
    # reads the commit and the build's variables to stamp the version.
    allowed: [Ehosctl.Build]

  # Here, since ehosctl is the package that depends on oidcc: elsewhere its modules are undefined.
  test "sees every call into oidcc, by its Elixir and its Erlang modules, a URL built included" do
    {:module, _module, beam, _} =
      defmodule Requests do
        @moduledoc false
        @compile :debug_info

        def token(code, context), do: Oidcc.Token.retrieve(code, context, %{})
        def url(context), do: Oidcc.Authorization.create_redirect_url(context, %{})
        def worker(name), do: Oidcc.ProviderConfiguration.Worker.refresh_jwks(name)
        def top(name), do: Oidcc.retrieve_token("code", name, "id", "secret", %{})
        def erlang(context), do: :oidcc_token.jwt_profile("subject", context, %{}, %{})
        def http(request), do: :oidcc_http_util.request(:post, request, %{topic: []}, %{})
        def another(term), do: OidccLike.read(term)
      end

    assert EhosTools.ConventionsCase.ways_out(beam) == [
             {Oidcc, :retrieve_token},
             {Oidcc.Authorization, :create_redirect_url},
             {Oidcc.ProviderConfiguration.Worker, :refresh_jwks},
             {Oidcc.Token, :retrieve},
             {:oidcc_http_util, :request},
             {:oidcc_token, :jwt_profile}
           ]
  end
end
