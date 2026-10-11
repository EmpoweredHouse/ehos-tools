defmodule Ehosctl.TerminalsTest do
  # `ehosctl terminals` and `ehosctl terminals sign-out`: one's own terminals, as the console's
  # settings list them and sign them out (eh-os#375, ehos-tools#111).
  use Ehosctl.SignInCase

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

  # This terminal's sign-in, as EHOS lists it: it signed in when the fake EHOS says it did.
  defp this_terminal(provider) do
    signed_in_at =
      provider.agent
      |> Agent.get(& &1.auth_time)
      |> DateTime.from_unix!()
      |> DateTime.to_iso8601()

    %{
      "id" => "fam-this",
      "signed_in_at" => signed_in_at,
      "last_used_at" => signed_in_at,
      "ends_at" => "2026-10-18T08:00:00Z"
    }
  end

  defp serve(provider, terminals),
    do:
      FakeProvider.stub_api(provider, "GET", "/api/v1/me/terminals", fn _ ->
        {200, %{"terminals" => terminals}}
      end)

  describe "terminals" do
    test "lists one's terminals as EHOS orders them, with every id whole, marking this one",
         %{provider: provider, opts: opts} do
      this = this_terminal(provider)
      serve(provider, [this, @older])

      {0, stdout, ""} = ehosctl(["terminals"], opts)
      [header, first, second] = String.split(stdout, "\n", trim: true)

      assert header =~ ~r/CURRENT\s+SIGNED IN\s+LAST USED\s+ENDS BY\s+ID/
      assert first =~ ~r/^\s*\*\s+.+ UTC\s+.+ UTC\s+2026-10-18 08:00 UTC\s+fam-this$/

      assert second =~
               ~r/^\s+2026-10-09 07:15 UTC\s+2026-10-10 16:02 UTC\s+2026-10-13 16:02 UTC\s+fam-older$/

      refute second =~ "*"
    end

    test "--json prints EHOS's answer, kept to the fields read, without the mark",
         %{provider: provider, opts: opts} do
      serve(provider, [Map.put(@older, "token_hash", "secret")])

      {0, stdout, ""} = ehosctl(["terminals", "--json"], opts)
      assert JSON.decode!(stdout) == %{"terminals" => [@older]}
    end

    test "marks none when several signed in at the second this one did",
         %{provider: provider, opts: opts} do
      this = this_terminal(provider)
      serve(provider, [this, %{this | "id" => "fam-twin"}])

      {0, stdout, ""} = ehosctl(["terminals"], opts)
      refute stdout =~ "*"
      assert stdout =~ "fam-this"
      assert stdout =~ "fam-twin"
    end

    test "says when no terminal is signed in", %{provider: provider, opts: opts} do
      serve(provider, [])

      assert {0, "No terminal is signed in.\n", ""} = ehosctl(["terminals"], opts)
      assert {0, ~s({"terminals":[]}\n), ""} = ehosctl(["terminals", "--json"], opts)
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

        assert {1, "", stderr} = ehosctl(["terminals"], opts)
        assert stderr =~ "answered with something ehosctl cannot read."
      end
    end

    test "prints an id with a terminal's control characters quoted",
         %{provider: provider, opts: opts} do
      serve(provider, [%{@older | "id" => "fam\e[2J"}])

      {0, stdout, ""} = ehosctl(["terminals"], opts)
      refute stdout =~ "\e"
      assert stdout =~ ~S("fam\e[2J")
    end

    test "EHOS's refusal is printed in its words, with its kind's exit code",
         %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "GET", "/api/v1/me/terminals", fn _ ->
        {401, %{"error" => "disabled", "message" => "Your account is disabled."}}
      end)

      assert {4, "", "ehosctl: Your account is disabled.\n"} = ehosctl(["terminals"], opts)
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

      assert {1, "", stderr} = ehosctl(["terminals"], opts)
      assert stderr =~ "runs EHOS 0.6.0, which has no `GET /api/v1/me/terminals`"
    end
  end

  describe "terminals sign-out" do
    test "signs one terminal out, naming it in the path, in the console's words",
         %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "DELETE", "/api/v1/me/terminals/:id", fn _ ->
        {200, %{"signed_out" => 1}}
      end)

      assert {0, stdout, ""} = ehosctl(["terminals", "sign-out", "fam-older"], opts)

      assert stdout ==
               "The terminal is signed out. It can no longer renew, so its commands stop " <>
                 "within ten minutes.\n"

      assert {0, ~s({"signed_out":1}\n), ""} =
               ehosctl(["terminals", "sign-out", "fam/older", "--json"], opts)

      assert [_] = FakeProvider.requests(provider, "DELETE /api/v1/me/terminals/fam-older")
      # An id is one segment of the path, whatever it holds.
      assert [_] = FakeProvider.requests(provider, "DELETE /api/v1/me/terminals/fam%2Folder")
    end

    test "a terminal signed out already, or not one's own, is EHOS's not_found, exit 1",
         %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "DELETE", "/api/v1/me/terminals/:id", fn _ ->
        {404, %{"error" => "not_found", "message" => "That terminal is signed out already."}}
      end)

      assert {1, "", "ehosctl: That terminal is signed out already.\n"} =
               ehosctl(["terminals", "sign-out", "fam-gone"], opts)

      assert {1, "", stderr} = ehosctl(["terminals", "sign-out", "fam-gone", "--json"], opts)

      assert JSON.decode!(stderr) == %{
               "error" => %{
                 "kind" => "failed",
                 "message" => "That terminal is signed out already."
               }
             }
    end

    test "an id that is a dot segment, or nothing, is refused before anything is sent",
         %{provider: provider, opts: opts} do
      for id <- ["", ".", ".."] do
        assert {2, "", stderr} = ehosctl(["terminals", "sign-out", id], opts)
        assert stderr =~ "names no terminal: `ehosctl terminals` lists them."
      end

      assert FakeProvider.requests(provider, "DELETE /api/v1/me/terminals/..") == []
    end

    test "an answer that is not one terminal signed out says to look",
         %{provider: provider, opts: opts} do
      for body <- [%{"signed_out" => 2}, %{"signed_out" => "1"}] do
        FakeProvider.stub_api(provider, "DELETE", "/api/v1/me/terminals/:id", fn _ ->
          {200, body}
        end)

        assert {1, "", stderr} = ehosctl(["terminals", "sign-out", "fam-older"], opts)
        assert stderr =~ "not as what was asked: run `ehosctl terminals` to see what was done."
      end

      FakeProvider.stub_api(provider, "DELETE", "/api/v1/me/terminals/:id", fn _ ->
        {200, %{"done" => true}}
      end)

      assert {1, "", stderr} = ehosctl(["terminals", "sign-out", "fam-older"], opts)
      assert stderr =~ "It said it was done: run `ehosctl terminals` to see."
    end

    test "a gateway's 5xx says it may have been done", %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "DELETE", "/api/v1/me/terminals/:id", fn _ ->
        {504, %{}}
      end)

      assert {5, "", stderr} = ehosctl(["terminals", "sign-out", "fam-older"], opts)
      assert stderr =~ "It may have been done: run `ehosctl terminals` to see."
    end
  end

  test "terminals' help names its subcommand and its plane", %{opts: opts} do
    {0, stdout, ""} = ehosctl(["terminals", "--help"], opts)
    assert stdout =~ "sign-out"
    assert stdout =~ "Plane: governed."
  end
end
