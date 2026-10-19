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

  defp api(provider, method, path, status, body),
    do: FakeProvider.stub_api(provider, method, path, fn _request -> {status, body} end)

  defp sent(provider, key) do
    [request | _] = FakeProvider.requests(provider, key)
    request
  end

  # A value from a pipe, as `printf … |` or `echo … |` gives it.
  defp piped(opts, input), do: Keyword.merge(opts, terminal?: false, read_stdin: fn -> input end)

  describe "list" do
    test "lists an environment's secrets with the newest version's setter, and never a value",
         %{provider: provider, opts: opts} do
      api(provider, "GET", @env_path, 200, %{"application" => "ledger", "secrets" => [@listed]})

      {0, stdout, ""} = ehosctl(~w(secret list --app ledger --env ledger-try), opts)

      assert stdout =~ "smtp_password"
      assert stdout =~ "ada@example.com"
      assert stdout =~ "2026-10-19T10:00:00Z"
      refute stdout =~ "ci-bot"

      {0, json, ""} = ehosctl(~w(secret list --app ledger --env ledger-try --json), opts)

      assert %{"application" => "ledger", "environment" => "ledger-try", "secrets" => [listed]} =
               JSON.decode!(json)

      assert listed == @listed
    end

    test "lists a template's defaults, and says when there are none",
         %{provider: provider, opts: opts} do
      api(provider, "GET", @template_path, 200, %{"application" => "ledger", "secrets" => []})

      {0, stdout, ""} = ehosctl(~w(secret list --app ledger --template small), opts)

      assert stdout =~ "ledger has no secrets as template small's default."
    end

    test "names one place: an environment or a template, not both and not neither",
         %{opts: opts} do
      assert {2, _stdout, stderr} = ehosctl(~w(secret list --app ledger), opts)
      assert stderr =~ "--env for an environment of the application, or --template"

      assert {2, _stdout, stderr} =
               ehosctl(~w(secret list --app ledger --env ledger-try --template small), opts)

      assert stderr =~ "name two places: give one"
    end

    test "says EHOS's refusal", %{provider: provider, opts: opts} do
      api(provider, "GET", @env_path, 403, %{
        "error" => "forbidden",
        "message" => "Managing ledger's secrets in ledger-try needs ehos.secret.manage there."
      })

      assert {3, _stdout, stderr} = ehosctl(~w(secret list --app ledger --env ledger-try), opts)
      assert stderr =~ "needs ehos.secret.manage there"
    end

    test "refuses an answer it cannot read", %{provider: provider, opts: opts} do
      api(provider, "GET", @env_path, 200, %{"secrets" => [%{"name" => "x"}]})

      assert {1, _stdout, stderr} = ehosctl(~w(secret list --app ledger --env ledger-try), opts)
      assert stderr =~ "answered with something ehosctl cannot read"
    end
  end

  describe "set" do
    test "sends a piped value in the body alone, never in the address, and never prints it",
         %{provider: provider, opts: opts} do
      api(provider, "PUT", @env_path <> "/smtp_password", 200, %{
        "secret" => %{"name" => "smtp_password", "version" => 3},
        "rotated" => ["d1", "d2"]
      })

      {0, stdout, stderr} =
        ehosctl(
          ~w(secret set smtp_password --app ledger --env ledger-try),
          piped(opts, @value <> "\n")
        )

      assert stdout =~ "Set smtp_password of ledger in ledger-try: version 3."
      assert stdout =~ "2 deployments roll to it."

      request = sent(provider, "PUT #{@env_path}/smtp_password")
      # `echo` ends with one line break, which is not part of the value.
      assert JSON.decode!(request.body) == %{"value" => @value}
      assert request.content_type =~ "application/json"
      assert request.query == %{}
      refute request.path =~ @value
      refute stdout =~ @value
      refute stderr =~ @value
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

      assert stdout =~ "Set signing_key of ledger as template small's default: version 1."
      refute stdout =~ "roll"

      assert JSON.decode!(sent(provider, "PUT #{@template_path}/signing_key").body) ==
               %{"value" => "-----BEGIN KEY-----\nabc\n-----END KEY-----\n"}
    end

    test "reads no value typed at a terminal, and sends nothing then",
         %{provider: provider, opts: opts} do
      {2, _stdout, stderr} =
        ehosctl(
          ~w(secret rotate smtp_password --app ledger --env ledger-try),
          Keyword.merge(opts, terminal?: true, read_stdin: fn -> flunk("read the terminal") end)
        )

      assert stderr =~ "smtp_password's value is not typed here"
      assert stderr =~ "give it with --from-file, or on standard input from a pipe or a file"
      assert FakeProvider.requests(provider, "PUT #{@env_path}/smtp_password") == []
    end

    test "reads standard input as bytes, so UTF-8 beyond ASCII is kept under any locale, and rotate is set",
         %{provider: provider, opts: opts, tmp_dir: tmp_dir} do
      api(provider, "PUT", @env_path <> "/smtp_password", 200, %{
        "secret" => %{"name" => "smtp_password", "version" => 1},
        "rotated" => ["d1"]
      })

      # A device in Unicode mode, as standard input is under a UTF-8 locale, and one in latin1.
      file = Path.join(tmp_dir, "value")
      File.write!(file, "zażółć €\n")

      for mode <- [:utf8, :binary] do
        {:ok, device} = File.open(file, [:read, mode])
        opts = Keyword.merge(opts, terminal?: false, stdin: device)

        assert {0, _stdout, ""} =
                 ehosctl(~w(secret rotate smtp_password --app ledger --env ledger-try), opts)

        File.close(device)
      end

      for request <- FakeProvider.requests(provider, "PUT #{@env_path}/smtp_password"),
          do: assert(JSON.decode!(request.body) == %{"value" => "zażółć €"})
    end

    test "sends nothing for an empty value, one that is not text, one too long, or a file it cannot read",
         %{provider: provider, opts: opts, tmp_dir: tmp_dir} do
      args = ~w(secret set smtp_password --app ledger --env ledger-try)

      assert {2, _stdout, stderr} = ehosctl(args, piped(opts, "\n"))
      assert stderr =~ "The value is empty"

      assert {2, _stdout, stderr} = ehosctl(args, piped(opts, <<0xFF, 0xFE>>))
      assert stderr =~ "is UTF-8 text, and this is not"

      assert {2, _stdout, stderr} = ehosctl(args, piped(opts, String.duplicate("a", 65_537)))
      assert stderr =~ "at most 65536 bytes, and this is longer"

      huge = Path.join(tmp_dir, "huge")
      File.write!(huge, String.duplicate("a", 65_539))
      assert {2, _stdout, stderr} = ehosctl(args ++ ["--from-file", huge], opts)
      assert stderr =~ "at most 65536 bytes, and this is longer"

      assert {2, _stdout, stderr} =
               ehosctl(~w(secret set k --app .. --env ledger-try), piped(opts, "v"))

      assert stderr =~ "--app .. names nothing"

      assert {2, _stdout, stderr} = ehosctl(~w(secret list --app ledger --env .), opts)
      assert stderr =~ "--env . names nothing"

      assert {2, _stdout, stderr} =
               ehosctl(args ++ ["--from-file", Path.join(tmp_dir, "missing")], opts)

      assert stderr =~ "cannot be read"

      # The bound is on what is read: 65536 bytes and a CRLF fit, one byte more does not.
      exact = Path.join(tmp_dir, "exact")
      File.write!(exact, String.duplicate("a", 65_537))
      assert {2, _stdout, stderr} = ehosctl(args ++ ["--from-file", exact], opts)
      assert stderr =~ "at most 65536 bytes"

      assert FakeProvider.requests(provider, "PUT #{@env_path}/smtp_password") == []
    end

    test "says EHOS's refusal of a name, without the value", %{provider: provider, opts: opts} do
      api(provider, "PUT", @env_path <> "/path", 422, %{
        "error" => "invalid",
        "message" => "A secret's name is not one the runtime reads or sets in every container.",
        "fields" => %{"name" => ["not one the runtime reads or sets in every container"]}
      })

      assert {2, _stdout, stderr} =
               ehosctl(~w(secret set path --app ledger --env ledger-try), piped(opts, @value))

      assert stderr =~ "the runtime reads or sets"
      refute stderr =~ @value
    end

    test "says the secret store did not answer", %{provider: provider, opts: opts} do
      api(provider, "PUT", @env_path <> "/smtp_password", 503, %{
        "error" => "secrets_unavailable",
        "message" => "The secret store did not answer, so nothing was set. Try again."
      })

      assert {5, _stdout, stderr} =
               ehosctl(
                 ~w(secret set smtp_password --app ledger --env ledger-try),
                 piped(opts, @value)
               )

      assert stderr =~ "nothing was set"
    end

    test "refuses an answer for another secret", %{provider: provider, opts: opts} do
      api(provider, "PUT", @env_path <> "/smtp_password", 200, %{
        "secret" => %{"name" => "other", "version" => 1},
        "rotated" => []
      })

      assert {1, _stdout, stderr} =
               ehosctl(
                 ~w(secret set smtp_password --app ledger --env ledger-try),
                 piped(opts, @value)
               )

      assert stderr =~ "run `ehosctl secret list` to see what was done"
    end
  end

  describe "delete" do
    test "deletes after asking, or with --yes", %{provider: provider, opts: opts} do
      api(provider, "DELETE", @env_path <> "/smtp_password", 200, %{
        "secret" => %{"name" => "smtp_password", "version" => 2}
      })

      confirm = fn question ->
        send(self(), {:asked, question})
        true
      end

      {0, stdout, ""} =
        ehosctl(
          ~w(secret delete smtp_password --app ledger --env ledger-try),
          Keyword.put(opts, :confirm, confirm)
        )

      assert_received {:asked,
                       "Delete smtp_password of ledger in ledger-try, with every version?"}

      assert stdout =~ "Deleted smtp_password of ledger in ledger-try, with every version."

      {0, _stdout, ""} =
        ehosctl(
          ~w(secret delete smtp_password --app ledger --env ledger-try --yes),
          Keyword.put(opts, :confirm, fn _ -> flunk("asked") end)
        )

      assert length(FakeProvider.requests(provider, "DELETE #{@env_path}/smtp_password")) == 2
    end

    test "deletes nothing on a no, or where nobody can answer", %{provider: provider, opts: opts} do
      args = ~w(secret delete smtp_password --app ledger --env ledger-try)

      assert {2, _stdout, stderr} = ehosctl(args, Keyword.put(opts, :confirm, fn _ -> false end))
      assert stderr =~ "Nothing was deleted."

      assert {2, _stdout, stderr} = ehosctl(args, Keyword.put(opts, :confirm, fn _ -> nil end))
      assert stderr =~ "answer on a terminal, or give --yes"

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

      assert {1, _stdout, stderr} =
               ehosctl(~w(secret delete smtp_password --app ledger --env ledger-try --yes), opts)

      assert stderr =~ "is what a deployment in ledger-try runs with"
      assert stderr =~ "Deployments that run with it: 5f0c1d2e, 6a1b2c3d."
    end

    test "refuses a name that names no secret", %{opts: opts} do
      assert {2, _stdout, stderr} =
               ehosctl(~w(secret delete .. --app ledger --env ledger-try --yes), opts)

      assert stderr =~ "names no secret"
    end
  end

  describe "what else it says" do
    test "keeps a piped value of several lines, less the last line break, and a pipe's CRLF",
         %{provider: provider, opts: opts} do
      api(provider, "PUT", @env_path <> "/signing_key", 200, %{
        "secret" => %{"name" => "signing_key", "version" => 4, "kept" => "extra"},
        "rotated" => ["d1"]
      })

      {0, stdout, ""} =
        ehosctl(
          ~w(secret set signing_key --app ledger --env ledger-try --json),
          piped(opts, "line one\nline two\n")
        )

      # Only the fields named reach a script.
      assert JSON.decode!(stdout) == %{
               "secret" => %{"name" => "signing_key", "version" => 4},
               "rotated" => ["d1"]
             }

      assert JSON.decode!(sent(provider, "PUT #{@env_path}/signing_key").body) ==
               %{"value" => "line one\nline two"}

      {0, stdout, ""} =
        ehosctl(~w(secret set signing_key --app ledger --env ledger-try), piped(opts, "v\r\n"))

      assert stdout =~ "1 deployment rolls to it."

      [_first, second] = FakeProvider.requests(provider, "PUT #{@env_path}/signing_key")
      assert JSON.decode!(second.body) == %{"value" => "v"}
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

    test "exits by EHOS's code, not its status", %{provider: provider, opts: opts} do
      # A 500 alone would exit 1; `secrets_unavailable` is Unavailable, 5.
      api(provider, "PUT", @env_path <> "/smtp_password", 500, %{
        "error" => "secrets_unavailable",
        "message" => "The secret store did not answer, so nothing was set. Try again."
      })

      assert {5, _stdout, _stderr} =
               ehosctl(
                 ~w(secret set smtp_password --app ledger --env ledger-try),
                 piped(opts, "v")
               )

      # A 409 alone would exit 1; `value_in_query` is Invalid, 2.
      api(provider, "PUT", @env_path <> "/smtp_password", 409, %{
        "error" => "value_in_query",
        "message" => "A secret's value goes in the request's body."
      })

      assert {2, _stdout, _stderr} =
               ehosctl(
                 ~w(secret set smtp_password --app ledger --env ledger-try),
                 piped(opts, "v")
               )

      api(provider, "GET", @env_path, 404, %{
        "error" => "not_found",
        "message" => "No application."
      })

      assert {1, _stdout, _stderr} = ehosctl(~w(secret list --app ledger --env ledger-try), opts)
    end

    test "adds nothing to a refusal whose body is not EHOS's object", %{
      provider: provider,
      opts: opts
    } do
      api(provider, "DELETE", @env_path <> "/smtp_password", 403, "Forbidden")

      assert {3, _stdout, stderr} =
               ehosctl(~w(secret delete smtp_password --app ledger --env ledger-try --yes), opts)

      assert stderr =~ ~r/answered HTTP 403\.\n\z/
    end
  end
end
