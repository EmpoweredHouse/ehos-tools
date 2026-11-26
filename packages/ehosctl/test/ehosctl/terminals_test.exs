defmodule Ehosctl.TerminalsTest do
  # `ehosctl terminals` and `ehosctl terminals sign-out`: one's own terminals, as the console's
  # settings list them and sign them out (eh-os#375, ehos-tools#111). Not async, through
  # `Ehosctl.SignInCase`: its `ehosctl/2` captures stderr, which every process shares.
  use Ehosctl.SignInCase

  @this %{
    "id" => "fam-this",
    "signed_in_at" => "2026-11-22T09:00:00Z",
    "last_used_at" => "2026-11-22T09:05:12Z",
    "ends_at" => "2026-11-29T09:00:00Z"
  }

  @older %{
    "id" => "fam-older",
    "signed_in_at" => "2026-10-09T07:15:00Z",
    "last_used_at" => "2026-10-10T16:02:41Z",
    "ends_at" => "2026-10-13T16:02:41Z"
  }

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    :ok
  end

  describe "terminals" do
    test "lists one's terminals as EHOS orders them, with every id whole",
         %{provider: provider, opts: opts} do
      serve(provider, [@this, @older])

      {0, stdout, ""} = ehosctl(["terminals"], opts)

      assert stdout == """
              SIGNED IN                    LAST USED                    ENDS BY                      ID
              22 November 2026, 09:00 UTC  22 November 2026, 09:05 UTC  29 November 2026, 09:00 UTC  fam-this
              9 October 2026, 07:15 UTC    10 October 2026, 16:02 UTC   13 October 2026, 16:02 UTC   fam-older
             """
    end

    test "--json prints EHOS's answer, kept to the fields read",
         %{provider: provider, opts: opts} do
      serve(provider, [Map.put(@older, "token_hash", "secret")])

      {0, stdout, ""} = ehosctl(["terminals", "--json"], opts)
      assert JSON.decode!(stdout) == %{"terminals" => [@older]}
    end

    test "says when no terminal is signed in", %{provider: provider, opts: opts} do
      serve(provider, [])

      assert ehosctl(["terminals"], opts) ==
               {0,
                "No terminal is signed in. A terminal shows here after you run `ehosctl login` on it.\n",
                ""}

      assert ehosctl(["terminals", "--json"], opts) == {0, ~s({"terminals":[]}\n), ""}
    end

    test "prints an id with a terminal's control characters quoted",
         %{provider: provider, opts: opts} do
      serve(provider, [%{@older | "id" => "fam\e[2J"}])

      {0, stdout, ""} = ehosctl(["terminals"], opts)

      assert stdout == ~S"""
              SIGNED IN                  LAST USED                   ENDS BY                     ID
              9 October 2026, 07:15 UTC  10 October 2026, 16:02 UTC  13 October 2026, 16:02 UTC  "fam\e[2J"
             """
    end

    test "an answer of another shape is one ehosctl cannot read", %{
      provider: provider,
      opts: opts
    } do
      for body <- [
            %{"terminals" => %{}},
            %{"sessions" => []},
            %{"terminals" => [Map.delete(@older, "ends_at")]},
            %{"terminals" => [%{@older | "last_used_at" => "yesterday"}]},
            %{"terminals" => [%{@older | "signed_in_at" => nil}]},
            %{"terminals" => [%{@older | "id" => ".."}]},
            %{"terminals" => [%{@older | "id" => 7}]},
            %{"terminals" => ["fam-older"]}
          ] do
        FakeProvider.stub_api(provider, "GET", "/api/v1/me/terminals", fn _ -> {200, body} end)

        assert ehosctl(["terminals"], opts) ==
                 {1, "",
                  "ehosctl: #{provider.issuer} answered with something ehosctl cannot read.\n"}
      end
    end

    test "EHOS's refusal is printed in its words, with its kind's exit code",
         %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "GET", "/api/v1/me/terminals", fn _ ->
        {401, %{"error" => "disabled", "message" => "Your account is disabled."}}
      end)

      assert ehosctl(["terminals"], opts) == {4, "", "ehosctl: Your account is disabled.\n"}
    end

    test "an EHOS without the route is said to need a later one", %{
      provider: provider,
      opts: opts
    } do
      FakeProvider.stub_api(provider, "GET", "/api/v1/me/terminals", fn _ ->
        {404, %{"errors" => %{"detail" => "Not Found"}}}
      end)

      FakeProvider.stub_api(provider, "GET", "/api/v1", fn _ ->
        {200,
         %{
           "component" => "ehos",
           "version" => "0.6.0",
           "produces" => ["ehos.api/v1"],
           "accepts" => [],
           "requires" => %{},
           "routes" => [%{"method" => "GET", "path" => "/api/v1/me/agents"}]
         }}
      end)

      assert ehosctl(["terminals"], opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} runs EHOS 0.6.0, which has no " <>
                  "`GET /api/v1/me/terminals`: this command needs a later EHOS. The operator " <>
                  "upgrades EHOS to have it.\n"}
    end
  end

  describe "terminals sign-out" do
    test "signs one terminal out, naming it in the path, in the console's words",
         %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "DELETE", "/api/v1/me/terminals/:id", fn _ ->
        {200, %{"signed_out" => 1}}
      end)

      assert ehosctl(["terminals", "sign-out", "fam-older"], opts) ==
               {0,
                "Signed out the terminal fam-older. It cannot renew its sign-in, so its " <>
                  "commands stop within 10 minutes.\n", ""}

      assert ehosctl(["terminals", "sign-out", "fam/older", "--json"], opts) ==
               {0, ~s({"signed_out":1}\n), ""}

      assert FakeProvider.requests(provider, "DELETE /api/v1/me/terminals/fam-older") == [
               %{
                 path: "/api/v1/me/terminals/fam-older",
                 query: %{},
                 body: "",
                 content_type: nil
               }
             ]

      # An id is one segment of the path, whatever it holds.
      assert FakeProvider.requests(provider, "DELETE /api/v1/me/terminals/fam%2Folder") == [
               %{
                 path: "/api/v1/me/terminals/fam%2Folder",
                 query: %{},
                 body: "",
                 content_type: nil
               }
             ]
    end

    test "a terminal signed out already, or not one's own, is EHOS's not_found, exit 1",
         %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "DELETE", "/api/v1/me/terminals/:id", fn _ ->
        {404, %{"error" => "not_found", "message" => "That terminal is signed out already."}}
      end)

      assert ehosctl(["terminals", "sign-out", "fam-gone"], opts) ==
               {1, "", "ehosctl: That terminal is signed out already.\n"}

      {1, "", stderr} = ehosctl(["terminals", "sign-out", "fam-gone", "--json"], opts)

      assert JSON.decode!(stderr) == %{
               "error" => %{
                 "kind" => "failed",
                 "message" => "That terminal is signed out already.",
                 "code" => "not_found"
               }
             }
    end

    test "an id that is a dot segment, or nothing, is refused before anything is sent",
         %{provider: provider, opts: opts} do
      for id <- ["", ".", ".."] do
        assert ehosctl(["terminals", "sign-out", id], opts) ==
                 {2, "",
                  "ehosctl: #{id} is not the id of a terminal.\n" <>
                    "What to do:\n" <>
                    "  See the ids:\n" <>
                    "  ehosctl terminals\n"}
      end

      assert FakeProvider.requests(provider, "DELETE /api/v1/me/terminals/..") == []
    end

    test "an answer that is not one terminal signed out says to look",
         %{provider: provider, opts: opts} do
      for body <- [%{"signed_out" => 2}, %{"signed_out" => "1"}] do
        FakeProvider.stub_api(provider, "DELETE", "/api/v1/me/terminals/:id", fn _ ->
          {200, body}
        end)

        assert ehosctl(["terminals", "sign-out", "fam-older"], opts) ==
                 {1, "",
                  "ehosctl: #{provider.issuer} answered with something ehosctl cannot read. It " <>
                    "answered that something was done, but not as what was asked.\nWhat to do:\n  See what was done:\n  ehosctl terminals --installation local\n"}
      end

      FakeProvider.stub_api(provider, "DELETE", "/api/v1/me/terminals/:id", fn _ ->
        {200, %{"done" => true}}
      end)

      assert ehosctl(["terminals", "sign-out", "fam-older"], opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} answered with something ehosctl cannot read. EHOS said that it made the change.\nWhat to do:\n  See it:\n  ehosctl terminals --installation local\n"}
    end

    test "a gateway's 5xx says it may have been done", %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "DELETE", "/api/v1/me/terminals/:id", fn _ ->
        {504, %{}}
      end)

      assert ehosctl(["terminals", "sign-out", "fam-older"], opts) ==
               {5, "",
                "ehosctl: #{provider.issuer} is unavailable (HTTP 504). Try again later. EHOS possibly made the change.\nWhat to do:\n  See whether it did before you run the command again:\n  ehosctl terminals --installation local\n"}
    end
  end

  test "terminals' help names its subcommand and its plane", %{opts: opts} do
    {0, stdout, ""} = ehosctl(["terminals", "--help"], opts)

    assert stdout == """
           ehosctl #{Ehosctl.version()}
           List your terminals that are signed in with `ehosctl login`, the newest first, and sign out a terminal.

           USAGE:
               ehosctl terminals [--json] [--installation NAME]

           FLAGS:

               --json        Print one JSON document instead of words.

           OPTIONS:

               --installation        The installation to talk to, instead of
                                     EHOSCTL_INSTALLATION or the current one.

           SUBCOMMANDS:

               sign-out        Sign out one of your terminals. The terminal cannot renew
                               its sign-in, so its commands stop within 10 minutes.

           Plane: governed. This command acts as you, through EHOS. EHOS decides and records each request.

           """
  end

  defp serve(provider, terminals),
    do:
      FakeProvider.stub_api(provider, "GET", "/api/v1/me/terminals", fn _ ->
        {200, %{"terminals" => terminals}}
      end)
end
