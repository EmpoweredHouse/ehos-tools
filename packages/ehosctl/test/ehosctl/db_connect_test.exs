defmodule Ehosctl.DbConnectTest do
  use Ehosctl.SignInCase

  alias Ehosctl.TestCA

  @now ~U[2026-10-28 12:00:00Z]
  @id "6f1c2a9e-5b7d-4c1e-9a2f-3d4e5f6a7b8c"
  @sessions "/api/v1/applications/ledger/environments/staging/sessions"
  @psql "/usr/local/bin/psql"
  @sleep "/bin/sleep"

  setup %{provider: provider, opts: opts} do
    stub_now(@now)
    FakeProvider.put_id_token_claims(provider, %{"auth_time" => DateTime.to_unix(@now)})

    data = ca("Data CA")
    gateway = ca("Gateway CA")

    api(provider, "GET", "/api/v1/data-ca", 200, %{
      "dataCa" => given(data),
      "gatewayCa" => given(gateway)
    })

    login!(provider, opts)

    stub(Ehosctl.OSMock, :find_executable, fn
      "psql" -> @psql
      "sleep" -> @sleep
    end)

    # A process that stands for the listener the tunnel's client starts.
    listener = spawn(fn -> Process.sleep(:infinity) end)
    stub(Ehosctl.TunnelMock, :port, fn ^listener -> 54_321 end)
    stub(Ehosctl.TunnelMock, :close, fn ^listener -> :ok end)
    api(provider, "DELETE", "/api/v1/sessions/#{@id}", 200, %{"session" => %{"id" => @id}})

    %{data: data, gateway: gateway, host: URI.parse(provider.issuer).host, listener: listener}
  end

  describe "db connect" do
    test "opens a session with a verifier and a key, runs psql through the tunnel, and ends it",
         %{
           provider: provider,
           opts: opts,
           data: data,
           gateway: gateway,
           host: host,
           listener: listener
         } do
      answer_session(provider, session(host, data, gateway))
      test = self()

      expect(Ehosctl.TunnelMock, :listen, fn listen ->
        send(test, {:listen, listen})
        {:ok, listener}
      end)

      expect(Ehosctl.RunnerMock, :foreground, fn @psql, [], env ->
        # What psql reads while it runs: the password file and the data CA.
        env = Map.new(env)
        send(test, {:psql, env, File.read!(env["PGPASSFILE"]), File.read!(env["PGSSLROOTCERT"])})
        0
      end)

      {code, stdout, stderr} =
        ehosctl(["db", "connect", "ledger", "--env", "staging", "--ttl", "30m"], opts)

      assert {code, stdout} == {0, ""}

      assert stderr ==
               "Opened the data session #{@id} on ledger in staging, to read, until 28 " <>
                 "October 2026, 13:00 UTC. psql starts.\nEnded the data session #{@id}.\n"

      [%{body: body}] = json_requests(provider, "POST #{@sessions}")
      assert Map.keys(body) == ["level", "publicKey", "ttl", "verifier"]
      assert %{"level" => "read", "ttl" => 1800} = body
      assert body["verifier"] =~ ~r/\ASCRAM-SHA-256\$4096:/

      assert_received {:listen, listen}
      assert listen[:url] == "wss://data.#{host}/v1/sessions/#{@id}/tunnel"
      assert EhosTunnel.Key.public_key(listen[:key]) == body["publicKey"]
      assert listen[:cacerts] == [der(gateway)]
      assert Keyword.keys(listen) == [:url, :key, :cacerts, :on_event]

      assert_received {:psql, env, passfile, root_cert}

      [line_host, "54321", "apps", "ehos_s_abc", password] =
        passfile |> String.trim() |> String.split(":")

      assert line_host == "ehos-ledger-rw.ehos-data.svc"
      assert password =~ ~r/\A[A-Za-z0-9_-]{43}\z/
      refute JSON.encode!(body) =~ password
      assert root_cert == data.certificate

      assert Map.drop(env, ["PGPASSFILE", "PGSSLROOTCERT"]) == %{
               "PGHOST" => "ehos-ledger-rw.ehos-data.svc",
               "PGHOSTADDR" => "127.0.0.1",
               "PGPORT" => "54321",
               "PGDATABASE" => "apps",
               "PGUSER" => "ehos_s_abc",
               "PGSSLMODE" => "verify-full",
               "PGCHANNELBINDING" => "require",
               "PGREQUIREAUTH" => "scram-sha-256",
               "PGAPPNAME" => "ehosctl db connect",
               "PGOPTIONS" =>
                 "-c statement_timeout=5min -c lock_timeout=5s " <>
                   "-c idle_in_transaction_session_timeout=1min",
               "PGPASSWORD" => nil,
               "PGSERVICE" => nil,
               "PGSERVICEFILE" => nil,
               "PGSSLCERT" => nil,
               "PGSSLKEY" => nil,
               "PGSSLCRL" => nil,
               "PGSSLCRLDIR" => nil,
               "PGSSLNEGOTIATION" => nil,
               "PGTARGETSESSIONATTRS" => nil,
               "PGCONNECT_TIMEOUT" => nil,
               "PGGSSENCMODE" => nil,
               "PGSSLMINPROTOCOLVERSION" => nil
             }

      # The files are gone, and the session ended at EHOS.
      refute File.exists?(env["PGPASSFILE"])
      refute File.exists?(env["PGSSLROOTCERT"])
      assert [_delete] = FakeProvider.requests(provider, "DELETE /api/v1/sessions/#{@id}")
    end

    test "exits as psql exits, and opens a session that writes with --write", %{
      provider: provider,
      opts: opts,
      data: data,
      gateway: gateway,
      host: host,
      listener: listener
    } do
      answer_session(provider, session(host, data, gateway))
      expect(Ehosctl.TunnelMock, :listen, fn _listen -> {:ok, listener} end)
      expect(Ehosctl.RunnerMock, :foreground, fn @psql, [], _env -> 2 end)

      {code, _stdout, stderr} =
        ehosctl(["db", "connect", "ledger", "--env", "staging", "--write"], opts)

      assert code == 2
      assert stderr =~ "to write"
      [%{body: body}] = json_requests(provider, "POST #{@sessions}")
      assert body["level"] == "write"
      refute Map.has_key?(body, "ttl")
    end

    test "ends a session whose answer names another gateway CA, and starts no psql", %{
      provider: provider,
      opts: opts,
      data: data,
      host: host
    } do
      answer_session(provider, session(host, data, ca("Gateway CA of someone else")))

      assert ehosctl(["db", "connect", "ledger", "--env", "staging"], opts) ==
               {1, "",
                "ehosctl: local gives a gateway CA with another key than the one ehosctl " <>
                  "keeps, so ehosctl does not trust it, and refuses data sessions that use it. " <>
                  "If your installation's administrator told you that the key changed, and " <>
                  "gave you its fingerprint, run `ehosctl db trust-ca FINGERPRINT` with it.\n"}

      assert [_delete] = FakeProvider.requests(provider, "DELETE /api/v1/sessions/#{@id}")
    end

    test "closes the listener and ends the session when the password file cannot be written", %{
      provider: provider,
      opts: opts,
      data: data,
      gateway: gateway,
      host: host,
      listener: listener
    } do
      answer_session(provider, session(host, data, gateway))
      expect(Ehosctl.TunnelMock, :listen, fn _listen -> {:ok, listener} end)
      expect(Ehosctl.TunnelMock, :close, fn ^listener -> :ok end)
      dir = Ehosctl.SessionFiles.dir(opts[:state_dir])
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o755)

      {1, "", stderr} = ehosctl(["db", "connect", "ledger", "--env", "staging"], opts)

      assert stderr =~ "so ehosctl does not keep the password of a data session there"
      assert [_delete] = FakeProvider.requests(provider, "DELETE /api/v1/sessions/#{@id}")
    end

    test "ends the session when psql cannot be started", %{
      provider: provider,
      opts: opts,
      data: data,
      gateway: gateway,
      host: host,
      listener: listener
    } do
      answer_session(provider, session(host, data, gateway))
      expect(Ehosctl.TunnelMock, :listen, fn _listen -> {:ok, listener} end)

      expect(Ehosctl.RunnerMock, :foreground, fn @psql, [], _env ->
        raise ErlangError, original: :enoent
      end)

      assert_raise ErlangError, fn ->
        ehosctl(["db", "connect", "ledger", "--env", "staging"], opts)
      end

      assert [_delete] = FakeProvider.requests(provider, "DELETE /api/v1/sessions/#{@id}")
      assert File.ls!(Ehosctl.SessionFiles.dir(opts[:state_dir])) == []
    end

    test "ends a session whose answer gives a CA that is not one certificate", %{
      provider: provider,
      opts: opts,
      data: data,
      gateway: gateway,
      host: host
    } do
      two = %{data | certificate: data.certificate <> gateway.certificate}
      answer_session(provider, session(host, two, gateway))

      assert ehosctl(["db", "connect", "ledger", "--env", "staging"], opts) ==
               {1, "",
                "ehosctl: local gave a data CA that is not one certificate with its own " <>
                  "fingerprint, so ehosctl does not trust it.\n"}

      assert [_delete] = FakeProvider.requests(provider, "DELETE /api/v1/sessions/#{@id}")
    end

    test "ends a session whose answer EHOS gave in another shape", %{
      provider: provider,
      opts: opts,
      data: data,
      gateway: gateway,
      host: host
    } do
      answer_session(provider, %{session(host, data, gateway) | "expires_at" => 1_801_224_000})

      {code, "", stderr} = ehosctl(["db", "connect", "ledger", "--env", "staging"], opts)

      assert code == 1
      assert stderr =~ "answered with something ehosctl cannot read"
      assert [_delete] = FakeProvider.requests(provider, "DELETE /api/v1/sessions/#{@id}")
    end

    test "ends a session whose tunnel is not the installation's data gateway", %{
      provider: provider,
      opts: opts,
      data: data,
      gateway: gateway,
      host: host
    } do
      session =
        put_in(
          session(host, data, gateway),
          ["tunnel", "url"],
          "wss://elsewhere.example.com/v1/sessions/#{@id}/tunnel"
        )

      answer_session(provider, session)

      assert ehosctl(["db", "connect", "ledger", "--env", "staging"], opts) ==
               {1, "",
                "ehosctl: EHOS gave a tunnel that is not the data gateway of the installation, " <>
                  "at data.#{host}. ehosctl does not use it.\n"}

      assert [_delete] = FakeProvider.requests(provider, "DELETE /api/v1/sessions/#{@id}")
    end

    test "says EHOS's refusal, and opens nothing", %{provider: provider, opts: opts} do
      api(provider, "POST", @sessions, 409, %{
        "error" => "too_many_sessions",
        "message" => "You opened 10 data sessions in the last hour. Try again later."
      })

      assert ehosctl(["db", "connect", "ledger", "--env", "staging"], opts) ==
               {1, "",
                "ehosctl: You opened 10 data sessions in the last hour. Try again later.\n"}
    end

    test "needs psql, a kept CA and a duration, before it asks EHOS", %{
      provider: provider,
      opts: opts
    } do
      stub(Ehosctl.OSMock, :find_executable, fn _name -> nil end)

      assert ehosctl(["db", "connect", "ledger", "--env", "staging"], opts) ==
               {1, "",
                "ehosctl: ehosctl db connect needs psql, the client of PostgreSQL, version 16 " <>
                  "or later. Install it, or use `ehosctl db tunnel` with another client.\n"}

      assert ehosctl(["db", "connect", "ledger", "--env", "staging", "--ttl", "30s"], opts) ==
               {2, "", "ehosctl: --ttl 30s is less than 1 minute. Give 1m or more.\n"}

      assert ehosctl(["db", "connect", "ledger", "--env", "staging", "--ttl", "soon"], opts) ==
               {2, "",
                "ehosctl: --ttl soon is not a duration. Give a number and a unit, such as 30m " <>
                  "or 2h.\n"}

      stub(Ehosctl.OSMock, :find_executable, fn _name -> @psql end)

      {:ok, _read, _written} =
        Config.update(opts[:config_dir], fn config ->
          {:ok, update_in(config.installations["local"], &Map.delete(&1, "data_ca"))}
        end)

      assert ehosctl(["db", "connect", "ledger", "--env", "staging"], opts) ==
               {1, "",
                "ehosctl: ehosctl keeps no data CA for local, so it cannot check a data session " <>
                  "there. Run `ehosctl login`. If the installation runs no data gateway, it " <>
                  "opens no data session.\n"}

      assert FakeProvider.requests(provider, "POST #{@sessions}") == []
    end
  end

  describe "db tunnel" do
    test "prints the connection, waits until Ctrl-C or the session's end, and ends it", %{
      provider: provider,
      opts: opts,
      data: data,
      gateway: gateway,
      host: host,
      listener: listener
    } do
      answer_session(provider, session(host, data, gateway))
      expect(Ehosctl.TunnelMock, :listen, fn _listen -> {:ok, listener} end)
      stub(Ehosctl.TerminalMock, :input_terminal?, fn -> true end)
      test = self()

      expect(Ehosctl.RunnerMock, :foreground, fn @sleep, ["3600"], [] ->
        send(test, :waited)
        130
      end)

      {code, stdout, stderr} = ehosctl(["db", "tunnel", "ledger", "--env", "staging"], opts)

      assert code == 0
      assert_received :waited
      assert stderr == "Ended the data session #{@id}.\n"

      [_all, password] = Regex.run(~r/Password +(\S+)/, stdout)
      [_all, root_cert] = Regex.run(~r/CA +(\S+)/, stdout)

      assert stdout ==
               """
               Opened the data session #{@id} on ledger in staging, to read, until 28 October 2026, 13:00 UTC.

               Connect a database client to it with these values:

                 Host          ehos-ledger-rw.ehos-data.svc
                 Address       127.0.0.1
                 Port          54321
                 Database      apps
                 User          ehos_s_abc
                 Password      #{password}
                 CA            #{root_cert}
                 Options       -c statement_timeout=5min -c lock_timeout=5s -c idle_in_transaction_session_timeout=1min

               libpq:  host=127.0.0.1 port=54321 dbname=apps user=ehos_s_abc sslmode=verify-ca sslrootcert=#{root_cert} channel_binding=require
               JDBC:   jdbc:postgresql://127.0.0.1:54321/apps?user=ehos_s_abc&sslmode=verify-ca&sslrootcert=#{root_cert}&channelBinding=require

               The client must verify the server against the CA and require channel binding: libpq 13 or
               later, pgjdbc 42.7.12 or later. If the client can give the host apart from the address, use
               sslmode=verify-full with the host. Give it the options too.

               Press Ctrl-C to end the data session. Without a terminal, it lasts until its end.
               """

      refute File.exists?(root_cert)
    end

    test "without a terminal, keeps the session until its end", %{
      provider: provider,
      opts: opts,
      data: data,
      gateway: gateway,
      host: host,
      listener: listener
    } do
      answer_session(provider, session(host, data, gateway))
      expect(Ehosctl.TunnelMock, :listen, fn _listen -> {:ok, listener} end)
      stub(Ehosctl.TerminalMock, :input_terminal?, fn -> false end)
      expect(Ehosctl.ClockMock, :sleep, fn 3_600_000 -> :ok end)

      {0, _stdout, stderr} = ehosctl(["db", "tunnel", "ledger", "--env", "staging"], opts)
      assert stderr == "Ended the data session #{@id}.\n"
    end
  end

  describe "the events of a tunnel" do
    test "each one that a person must know is said" do
      host = "data.ehos.example.com"

      said =
        for event <- [
              {:open, self()},
              {:ended, self()},
              {:refused, self(), %{status: 403}},
              {:refused, self(), %{status: 409, end_reason: :expired}},
              {:refused, self(), %{status: 429}},
              {:refused, self(), %{status: 502}},
              {:refused, self(), %{status: 503}},
              {:closed, self(), %{code: 4001, end_reason: :revoked}},
              {:closed, self(), %{code: 4001, end_reason: :deployment}},
              {:closed, self(), %{code: 1001}},
              {:failed, self(), :timeout},
              {:failed, self(), %Mint.TransportError{reason: :econnrefused}}
            ],
            do: Ehosctl.DataSession.said(event, host)

      assert said == [
               nil,
               nil,
               "The data gateway refused a connection: the data session does not exist, or it " <>
                 "is not the session of this key.",
               "The data gateway refused a connection: the data session expired. Open a new one.",
               "The data gateway refused a connection: the data session has 3 connections " <>
                 "open, or the gateway is full. Close a connection, then try again.",
               "The data gateway cannot reach the database. Try again later.",
               "The data gateway opens no new connection, because EHOS does not answer it now. " <>
                 "Connections that are open stay open. Try again later.",
               "The data gateway closed a connection: you no longer hold a role that gives " <>
                 "this data session, so EHOS ended it.",
               "The data gateway closed a connection: a deployment of the application ended " <>
                 "the data session. Open a new one.",
               "The data gateway restarted and closed a connection. Connect again.",
               "The data gateway at data.ehos.example.com did not answer in time. Try again later.",
               "ehosctl could not reach the data gateway at data.ehos.example.com: connection refused"
             ]
    end
  end

  defp answer_session(provider, session),
    do: api(provider, "POST", @sessions, 201, %{"session" => session})

  defp session(host, data, gateway),
    do: %{
      "id" => @id,
      "application" => "ledger",
      "environment" => "staging",
      "level" => "read",
      "role" => "ehos_s_abc",
      "state" => "open",
      "opened_at" => "2026-10-28T12:00:00Z",
      "expires_at" => "2026-10-28T13:00:00Z",
      "ended_at" => nil,
      "end_reason" => nil,
      "tunnel" => %{
        "url" => "wss://data.#{host}/v1/sessions/#{@id}/tunnel",
        "protocol" => "ehos-tunnel.v1"
      },
      "database" => %{
        "host" => "ehos-ledger-rw.ehos-data.svc",
        "port" => 5432,
        "name" => "apps",
        "user" => "ehos_s_abc"
      },
      "dataCa" => given(data),
      "gatewayCa" => given(gateway)
    }

  defp ca(name) do
    pem = TestCA.certificate(name, :public_key.generate_key({:namedCurve, :secp256r1}))
    {:ok, key_sha256} = Ehosctl.DataCa.fingerprint(pem)
    %{certificate: pem, key_sha256: key_sha256}
  end

  defp der(%{certificate: pem}) do
    [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(pem)
    der
  end

  defp given(%{certificate: pem, key_sha256: key_sha256}),
    do: %{"certificate" => pem, "keySha256" => key_sha256}
end
