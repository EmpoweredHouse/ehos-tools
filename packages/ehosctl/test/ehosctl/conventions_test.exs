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
  test "sees each of oidcc's requests, by its Elixir and its Erlang modules, and not its URLs" do
    {:module, _module, beam, _} =
      defmodule Requests do
        @moduledoc false
        @compile :debug_info

        def token(code, context), do: Oidcc.Token.retrieve_with_refresh(code, context, %{})
        def credentials(context), do: Oidcc.Token.client_credentials(context, %{})
        def userinfo(token, context), do: Oidcc.Userinfo.retrieve(token, context, %{})
        def erlang(context), do: :oidcc_token.jwt_profile("subject", context, %{}, %{})
        def url(context), do: Oidcc.Authorization.create_redirect_url(context, %{})
      end

    assert EhosTools.ConventionsCase.ways_out(beam) == [
             {Oidcc.Token, :client_credentials},
             {Oidcc.Token, :retrieve_with_refresh},
             {Oidcc.Userinfo, :retrieve},
             {:oidcc_token, :jwt_profile}
           ]
  end
end
