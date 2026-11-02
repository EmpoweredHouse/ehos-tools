defmodule Ehosctl.SecretsTest do
  use Ehosctl.SignInCase

  @env_path "/api/v1/applications/ledger/environments/ledger-try/secrets"
  @template_path "/api/v1/applications/ledger/templates/small/secrets"
  @value "s3cr3t-value-never-printed"

  @listed %{
    "name" => "smtp_password",
    "version" => 2,
    "updated_at" => "2026-10-19T10:00:00Z",
    "versions" => [
      %{"version" => 2, "set_by" => "ada@example.com", "set_at" => "2026-10-19T10:00:00Z"},
      %{"version" => 1, "set_by" => "ci-bot", "set_at" => "2026-10-18T09:00:00Z"}
    ]
  }

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    %{opts: opts}
  end

  describe "secret list" do
    test "lists an environment's secrets with the newest version's setter, and never a value",
         %{provider: provider, opts: opts} do
      api(provider, "GET", @env_path, 200, %{"application" => "ledger", "secrets" => [@listed]})

      {0, stdout, ""} = ehosctl(~w(secret list --app ledger --env ledger-try), opts)

      assert stdout == """
              NAME           VERSION  SET BY           SET AT
              smtp_password  2        ada@example.com  2026-10-19T10:00:00Z
             """

      {0, json, ""} = ehosctl(~w(secret list --app ledger --env ledger-try --json), opts)

      assert JSON.decode!(json) == %{
               "application" => "ledger",
               "environment" => "ledger-try",
               "secrets" => [@listed]
             }
    end

    test "lists a template's defaults, and says when there are none",
         %{provider: provider, opts: opts} do
      api(provider, "GET", @template_path, 200, %{"application" => "ledger", "secrets" => []})

      {0, stdout, ""} = ehosctl(~w(secret list --app ledger --template small), opts)

      assert stdout ==
               "ledger has no secrets as the default of the environment template small. A secret " <>
                 "shows here when a person sets it with `ehosctl secret set`.\n"
    end

    test "names one place: an environment or a template, not both and not neither",
         %{opts: opts} do
      assert ehosctl(~w(secret list --app ledger), opts) ==
               {2, "",
                "ehosctl: The command does not say where the secret is. Give --env for an " <>
                  "environment of the application, or --template for an environment " <>
                  "template.\n"}

      assert ehosctl(~w(secret list --app ledger --env ledger-try --template small), opts) ==
               {2, "", "ehosctl: --env and --template name two places. Give only one of them.\n"}
    end

    test "says EHOS's refusal", %{provider: provider, opts: opts} do
      api(provider, "GET", @env_path, 403, %{
        "error" => "forbidden",
        "message" => "Managing ledger's secrets in ledger-try needs ehos.secret.manage there."
      })

      assert ehosctl(~w(secret list --app ledger --env ledger-try), opts) ==
               {3, "",
                "ehosctl: Managing ledger's secrets in ledger-try needs ehos.secret.manage there.\n"}
    end

    test "refuses an answer it cannot read", %{provider: provider, opts: opts} do
      api(provider, "GET", @env_path, 200, %{"secrets" => [%{"name" => "x"}]})

      assert ehosctl(~w(secret list --app ledger --env ledger-try), opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} answered with something ehosctl cannot read.\n"}
    end
  end

  describe "secret set" do
    test "sends a piped value in the body alone, never in the address, and never prints it",
         %{provider: provider, opts: opts} do
      api(provider, "PUT", @env_path <> "/smtp_password", 200, %{
        "secret" => %{"name" => "smtp_password", "version" => 3},
        "rotated" => ["d1", "d2"]
      })

      mock_stdin(@value <> "\n")

      # Neither output holds the value.
      assert ehosctl(~w(secret set smtp_password --app ledger --env ledger-try), opts) ==
               {0,
                "Set smtp_password of ledger in ledger-try: version 3. 2 deployments roll to it.\n",
                ""}

      # `echo` ends with one line break, which is not part of the value.
      assert FakeProvider.requests(provider, "PUT #{@env_path}/smtp_password") == [
               %{
                 path: "#{@env_path}/smtp_password",
                 query: %{},
                 body: JSON.encode!(%{"value" => @value}),
                 content_type: "application/json"
               }
             ]
    end

    test "keeps a file's value as the file holds it, line break included, as a template's default",
         %{provider: provider, opts: opts, tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "key.pem")
      File.write!(file, "-----BEGIN KEY-----\nabc\n-----END KEY-----\n")

      api(provider, "PUT", @template_path <> "/signing_key", 200, %{
        "secret" => %{"name" => "signing_key", "version" => 1},
        "rotated" => []
      })

      {0, stdout, ""} =
        ehosctl(
          [
            "secret",
            "set",
            "signing_key",
            "--app",
            "ledger",
            "--template",
            "small",
            "--from-file",
            file
          ],
          Keyword.put(opts, :read_stdin, fn -> flunk("read standard input") end)
        )

      # With no deployment to roll, none is named.
      assert stdout ==
               "Set signing_key of ledger as the default of the environment template small: " <>
                 "version 1.\n"

      assert sent_values(provider, "PUT #{@template_path}/signing_key") == [
               "-----BEGIN KEY-----\nabc\n-----END KEY-----\n"
             ]
    end

    # Standard input is read as bytes (`Ehosctl.TerminalTest`), so UTF-8 beyond ASCII is kept.
    test "sends UTF-8 beyond ASCII as it was piped, and rotate is set",
         %{provider: provider, opts: opts} do
      api(provider, "PUT", @env_path <> "/smtp_password", 200, %{
        "secret" => %{"name" => "smtp_password", "version" => 1},
        "rotated" => ["d1"]
      })

      mock_stdin("zażółć €\n")

      assert ehosctl(~w(secret rotate smtp_password --app ledger --env ledger-try), opts) ==
               {0,
                "Set smtp_password of ledger in ledger-try: version 1. 1 deployment rolls to it.\n",
                ""}

      assert sent_values(provider, "PUT #{@env_path}/smtp_password") == ["zażółć €"]
    end

    test "keeps a piped value of several lines, less the last line break, and a pipe's CRLF",
         %{provider: provider, opts: opts} do
      api(provider, "PUT", @env_path <> "/signing_key", 200, %{
        "secret" => %{"name" => "signing_key", "version" => 4, "kept" => "extra"},
        "rotated" => ["d1"]
      })

      mock_stdin("line one\nline two\n")

      {0, stdout, ""} =
        ehosctl(
          ~w(secret set signing_key --app ledger --env ledger-try --json),
          opts
        )

      # Only the fields named reach a script.
      assert JSON.decode!(stdout) == %{
               "secret" => %{"name" => "signing_key", "version" => 4},
               "rotated" => ["d1"]
             }

      mock_stdin("v\r\n")

      assert ehosctl(~w(secret set signing_key --app ledger --env ledger-try), opts) ==
               {0,
                "Set signing_key of ledger in ledger-try: version 4. 1 deployment rolls to it.\n",
                ""}

      assert sent_values(provider, "PUT #{@env_path}/signing_key") == ["line one\nline two", "v"]
    end

    test "reads no value typed at a terminal, and sends nothing then",
         %{provider: provider, opts: opts} do
      mock_terminal_unread()

      {2, "", stderr} =
        ehosctl(~w(secret rotate smtp_password --app ledger --env ledger-try), opts)

      assert stderr ==
               "ehosctl: ehosctl does not read the value of smtp_password from a terminal, " <>
                 "which can show or keep it. Nothing was set. Give the value with --from-file, " <>
                 "or from a pipe or a file, as in " <>
                 "`ehosctl secret set smtp_password … < value.txt`.\n"

      assert FakeProvider.requests(provider, "PUT #{@env_path}/smtp_password") == []
    end

    test "sends nothing for an empty value, one that is not text, one too long, or a file it cannot read",
         %{provider: provider, opts: opts, tmp_dir: tmp_dir} do
      args = ~w(secret set smtp_password --app ledger --env ledger-try)

      too_long =
        "ehosctl: The value is longer than 65536 bytes, the most that EHOS accepts. " <>
          "Nothing was set.\n"

      mock_stdin("\n")

      assert ehosctl(args, opts) ==
               {2, "",
                "ehosctl: The value is empty, so nothing was set. Give the value on standard " <>
                  "input or with --from-file.\n"}

      mock_stdin(<<0xFF, 0xFE>>)

      assert ehosctl(args, opts) ==
               {2, "",
                "ehosctl: The value is not UTF-8 text, so nothing was set. EHOS accepts only " <>
                  "UTF-8 text.\n"}

      mock_stdin(String.duplicate("a", 65_537))
      assert ehosctl(args, opts) == {2, "", too_long}

      huge = Path.join(tmp_dir, "huge")
      File.write!(huge, String.duplicate("a", 65_539))
      assert ehosctl(args ++ ["--from-file", huge], opts) == {2, "", too_long}

      mock_stdin("v")

      assert ehosctl(~w(secret set k --app .. --env ledger-try), opts) ==
               {2, "", "ehosctl: --app .. is not a name. Give the name of the application.\n"}

      assert ehosctl(~w(secret list --app ledger --env .), opts) ==
               {2, "", "ehosctl: --env . is not a name. Give the name of the environment.\n"}

      missing = Path.join(tmp_dir, "missing")

      assert ehosctl(args ++ ["--from-file", missing], opts) ==
               {2, "",
                "ehosctl: ehosctl cannot read #{missing}: no such file or directory. Nothing was set.\n"}

      # The bound is on what is read: 65536 bytes and a CRLF fit, one byte more does not.
      exact = Path.join(tmp_dir, "exact")
      File.write!(exact, String.duplicate("a", 65_537))
      assert ehosctl(args ++ ["--from-file", exact], opts) == {2, "", too_long}

      assert FakeProvider.requests(provider, "PUT #{@env_path}/smtp_password") == []
    end

    test "says EHOS's refusal of a name, without the value", %{provider: provider, opts: opts} do
      api(provider, "PUT", @env_path <> "/path", 422, %{
        "error" => "invalid",
        "message" => "A secret's name is not one the runtime reads or sets in every container.",
        "fields" => %{"name" => ["not one the runtime reads or sets in every container"]}
      })

      mock_stdin(@value)

      assert ehosctl(~w(secret set path --app ledger --env ledger-try), opts) ==
               {2, "",
                "ehosctl: A secret's name is not one the runtime reads or sets in every container.\n"}
    end

    test "says the secret store did not answer", %{provider: provider, opts: opts} do
      api(provider, "PUT", @env_path <> "/smtp_password", 503, %{
        "error" => "secrets_unavailable",
        "message" => "The secret store did not answer, so nothing was set. Try again."
      })

      mock_stdin(@value)

      assert ehosctl(~w(secret set smtp_password --app ledger --env ledger-try), opts) ==
               {5, "",
                "ehosctl: The secret store did not answer, so nothing was set. Try again.\n"}
    end

    test "exits by EHOS's code, not its status", %{provider: provider, opts: opts} do
      # A 500 alone would exit 1; `secrets_unavailable` is Unavailable, 5.
      api(provider, "PUT", @env_path <> "/smtp_password", 500, %{
        "error" => "secrets_unavailable",
        "message" => "The secret store did not answer, so nothing was set. Try again."
      })

      mock_stdin("v")

      assert ehosctl(~w(secret set smtp_password --app ledger --env ledger-try), opts) ==
               {5, "",
                "ehosctl: The secret store did not answer, so nothing was set. Try again.\n"}

      # A 409 alone would exit 1; `value_in_query` is Invalid, 2.
      api(provider, "PUT", @env_path <> "/smtp_password", 409, %{
        "error" => "value_in_query",
        "message" => "A secret's value goes in the request's body."
      })

      mock_stdin("v")

      assert ehosctl(~w(secret set smtp_password --app ledger --env ledger-try), opts) ==
               {2, "", "ehosctl: A secret's value goes in the request's body.\n"}

      api(provider, "GET", @env_path, 404, %{
        "error" => "not_found",
        "message" => "No application."
      })

      assert ehosctl(~w(secret list --app ledger --env ledger-try), opts) ==
               {1, "", "ehosctl: No application.\n"}
    end

    test "refuses an answer for another secret", %{provider: provider, opts: opts} do
      api(provider, "PUT", @env_path <> "/smtp_password", 200, %{
        "secret" => %{"name" => "other", "version" => 1},
        "rotated" => []
      })

      mock_stdin(@value)

      assert ehosctl(~w(secret set smtp_password --app ledger --env ledger-try), opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} answered with something ehosctl cannot read. It " <>
                  "answered that something was done, but not as what was asked: run " <>
                  "`ehosctl secret list` to see what was done.\n"}
    end
  end

  describe "secret delete" do
    test "deletes after asking, or with --yes", %{provider: provider, opts: opts} do
      api(provider, "DELETE", @env_path <> "/smtp_password", 200, %{
        "secret" => %{"name" => "smtp_password", "version" => 2}
      })

      mock_terminal_answer("y\n")

      {0, stdout, stderr} =
        ehosctl(~w(secret delete smtp_password --app ledger --env ledger-try), opts)

      assert stderr ==
               "Delete smtp_password of ledger in ledger-try, and all its versions? [y/N] "

      assert stdout == "Deleted smtp_password of ledger in ledger-try, and all its versions.\n"

      mock_no_question()

      assert ehosctl(~w(secret delete smtp_password --app ledger --env ledger-try --yes), opts) ==
               {0, "Deleted smtp_password of ledger in ledger-try, and all its versions.\n", ""}

      deleted = %{path: "#{@env_path}/smtp_password", query: %{}, body: "", content_type: nil}

      assert FakeProvider.requests(provider, "DELETE #{@env_path}/smtp_password") ==
               [deleted, deleted]
    end

    test "deletes a template's default, and prints only its name and version under --json",
         %{provider: provider, opts: opts} do
      api(provider, "DELETE", @template_path <> "/smtp_password", 200, %{
        "secret" => %{"name" => "smtp_password", "version" => 2, "kept" => "extra"}
      })

      {0, stdout, ""} =
        ehosctl(~w(secret delete smtp_password --app ledger --template small --yes --json), opts)

      assert JSON.decode!(stdout) == %{"secret" => %{"name" => "smtp_password", "version" => 2}}
    end

    test "deletes nothing on a no, or where nobody can answer", %{provider: provider, opts: opts} do
      args = ~w(secret delete smtp_password --app ledger --env ledger-try)

      mock_terminal_answer("n\n")

      assert ehosctl(args, opts) ==
               {2, "",
                "Delete smtp_password of ledger in ledger-try, and all its versions? [y/N] " <>
                  "ehosctl: You did not confirm, so nothing was deleted.\n"}

      # Without a terminal, nothing is asked.
      mock_no_terminal()
      mock_no_question()

      assert ehosctl(args, opts) ==
               {2, "",
                "ehosctl: Nothing was deleted: ehosctl asks before it deletes smtp_password, " <>
                  "and nobody can answer here. Answer on a terminal, or give --yes.\n"}

      assert FakeProvider.requests(provider, "DELETE #{@env_path}/smtp_password") == []
    end

    test "names the deployments that run with a secret EHOS keeps", %{
      provider: provider,
      opts: opts
    } do
      api(provider, "DELETE", @env_path <> "/smtp_password", 409, %{
        "error" => "in_use",
        "message" =>
          "smtp_password is what a deployment in ledger-try runs with; it is deleted once no " <>
            "deployment that may be in force resolves to it.",
        "deployments" => ["5f0c1d2e", "6a1b2c3d"]
      })

      assert ehosctl(~w(secret delete smtp_password --app ledger --env ledger-try --yes), opts) ==
               {1, "",
                "ehosctl: smtp_password is what a deployment in ledger-try runs with; it is " <>
                  "deleted once no deployment that may be in force resolves to it. The " <>
                  "deployments that run with it: 5f0c1d2e, 6a1b2c3d.\n"}
    end

    test "refuses a name that names no secret", %{opts: opts} do
      assert ehosctl(~w(secret delete .. --app ledger --env ledger-try --yes), opts) ==
               {2, "",
                "ehosctl: .. is not the name of a secret. Give a name in lowercase, such as " <>
                  "smtp_password.\n"}
    end

    test "adds nothing to a refusal whose body is not EHOS's object", %{
      provider: provider,
      opts: opts
    } do
      api(provider, "DELETE", @env_path <> "/smtp_password", 403, "Forbidden")

      assert ehosctl(~w(secret delete smtp_password --app ledger --env ledger-try --yes), opts) ==
               {3, "", "ehosctl: #{provider.issuer} answered HTTP 403.\n"}
    end
  end

  # The values sent to `key`, oldest first, each read from its body.
  defp sent_values(provider, key) do
    for request <- FakeProvider.requests(provider, key),
        do: Map.fetch!(JSON.decode!(request.body), "value")
  end

  # A person at a terminal, who answers `answer`.
  defp mock_terminal_answer(answer) do
    stub(Ehosctl.TerminalMock, :input_terminal?, fn -> true end)
    stub(Ehosctl.TerminalMock, :error_terminal?, fn -> true end)
    stub(Ehosctl.TerminalMock, :gets, fn "" -> answer end)
  end

  # A terminal, at which a value would be typed: nothing is read from it.
  defp mock_terminal_unread do
    stub(Ehosctl.TerminalMock, :input_terminal?, fn -> true end)
    expect(Ehosctl.TerminalMock, :read_input, 0, fn _count -> :eof end)
  end

  # No terminal to answer at.
  defp mock_no_terminal, do: stub(Ehosctl.TerminalMock, :input_terminal?, fn -> false end)

  # Nothing is asked.
  defp mock_no_question, do: expect(Ehosctl.TerminalMock, :gets, 0, fn _prompt -> nil end)

  # A value from a pipe, as `printf … |` or `echo … |` gives it, read as standard input is.
  defp mock_stdin(input) do
    stub(Ehosctl.TerminalMock, :read_input, fn count ->
      if input == "", do: :eof, else: binary_part(input, 0, min(count, byte_size(input)))
    end)
  end
end
