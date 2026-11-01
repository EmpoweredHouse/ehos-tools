defmodule Ehosctl.SignInTest do
  use Ehosctl.Case, async: true

  import ExUnit.CaptureLog

  alias Ehosctl.FakeIssuer
  alias Ehosctl.HTTP
  alias Ehosctl.HTTPImpl
  alias Ehosctl.SignIn
  alias Ehosctl.SignIn.Loopback
  alias Ehosctl.SignInImpl

  doctest Ehosctl.SignIn
  doctest Ehosctl.SignIn.Page

  # A sign-in's request, and the issuer it was sent to, as `SignIn.callback/3` reads them.
  @request %{state: "the-state", nonce: "n", verifier: "v", redirect_uri: "r"}
  @issuer "https://ehos.example.com"

  describe "origin/1" do
    test "keeps an origin, lowercased, without a trailing slash" do
      assert SignIn.origin("https://ehos.example.com") == {:ok, "https://ehos.example.com"}

      assert SignIn.origin("https://ehos.example.com:8443/") ==
               {:ok, "https://ehos.example.com:8443"}
    end

    test "refuses plain HTTP, even on this machine" do
      for url <- ~w(http://ehos.example.com http://localhost:4000 http://127.0.0.1:4000) do
        assert SignIn.origin(url) ==
                 {:error, :invalid, "#{url} is plain HTTP; EHOS signs people in over https only"}
      end
    end

    test "refuses anything but an origin" do
      for url <- [
            "https://ehos.example.com/console",
            "https://ehos.example.com/?a=b",
            "https://ehos.example.com/#x",
            "https://grace:secret@ehos.example.com",
            "https://ehos.example.com\u202E",
            "https://ehos.example.com\n",
            "https://ehos example.com",
            "file:///etc/passwd",
            "https://",
            ""
          ] do
        assert SignIn.origin(url) ==
                 {:error, :invalid,
                  "#{inspect(url)} is not an installation's address, such as " <>
                    "https://ehos.example.com"},
               inspect(url)
      end
    end
  end

  describe "EHOSCTL_CA_FILE" do
    @describetag :tmp_dir

    # An https server on a local port of this machine alone, with a certificate for localhost from
    # a CA of its own, which answers every request with a 404, as an address with no discovery
    # document does.
    setup %{tmp_dir: dir} do
      san = {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost"]}

      %{server_config: server, client_config: client} =
        :public_key.pkix_test_data(%{
          server_chain: %{
            root: [key: {:rsa, 2048, 65_537}, digest: :sha256],
            intermediates: [],
            peer: [key: {:rsa, 2048, 65_537}, digest: :sha256, extensions: [san]]
          },
          client_chain: %{
            root: [key: {:rsa, 2048, 65_537}],
            intermediates: [],
            peer: [key: {:rsa, 2048, 65_537}]
          }
        })

      {:ok, listener} =
        :ssl.listen(
          0,
          server ++ [active: false, reuseaddr: true, log_level: :none, ip: {127, 0, 0, 1}]
        )

      {:ok, {{127, 0, 0, 1}, port}} = :ssl.sockname(listener)
      server = spawn(fn -> serve(listener) end)
      :ok = :ssl.controlling_process(listener, server)
      on_exit(fn -> Process.exit(server, :kill) end)

      ca = Path.join(dir, "ca.pem")
      pem = for der <- client[:cacerts], do: {:Certificate, der, :not_encrypted}
      File.write!(ca, :public_key.pem_encode(pem))

      # Another CA, which signed nothing the server sends.
      other = Path.join(dir, "other.pem")
      %{cert: der} = :public_key.pkix_test_root_cert(~c"Another CA", [])
      File.write!(other, :public_key.pem_encode([{:Certificate, der, :not_encrypted}]))

      %{issuer: "https://localhost:#{port}", ca: ca, other: other}
    end

    test "a certificate from the CA it names is trusted", %{issuer: issuer, ca: ca} do
      stub_env(%{"EHOSCTL_CA_FILE" => ca})

      assert SignInImpl.provider(issuer, []) == no_discovery(issuer)
    end

    test "a certificate from the CA kept for the installation is trusted with no variable set",
         %{issuer: issuer, ca: ca} do
      opts = [ca: {"staging", File.read!(ca)}]

      assert SignInImpl.provider(issuer, opts) == no_discovery(issuer)
      assert HTTPImpl.request(:get, issuer, "credential", nil, opts) == not_found()
    end

    test "HTTP.request/5 trusts it too", %{issuer: issuer, ca: ca} do
      stub_env(%{"EHOSCTL_CA_FILE" => ca})

      assert HTTPImpl.request(:get, issuer, "credential", nil, []) == not_found()
    end

    test "ca_file_pem/1 gives the file's certificates alone, encoded again", %{
      ca: ca,
      tmp_dir: dir
    } do
      noisy = Path.join(dir, "noisy.pem")
      File.write!(noisy, "a comment\n" <> File.read!(ca) <> "trailing words\n")

      assert Ehosctl.TLS.ca_file_pem(%{}) == {:ok, nil}
      assert Ehosctl.TLS.ca_file_pem(%{"EHOSCTL_CA_FILE" => ""}) == {:ok, nil}
      assert Ehosctl.TLS.ca_file_pem(%{"EHOSCTL_CA_FILE" => noisy}) == {:ok, File.read!(ca)}

      none = Path.join(dir, "none.pem")

      assert Ehosctl.TLS.ca_file_pem(%{"EHOSCTL_CA_FILE" => none}) ==
               {:error, :invalid,
                "cannot read EHOSCTL_CA_FILE=#{none}: no such file or directory"}
    end

    test "a certificate from that CA for another name is refused", %{issuer: issuer, ca: ca} do
      stub_env(%{"EHOSCTL_CA_FILE" => ca})
      # The server's certificate names localhost alone.
      elsewhere = String.replace(issuer, "localhost", "127.0.0.1")

      # The CA is trusted, so the handshake fails on the name alone, not as unknown_ca.
      bad_certificate =
        {:error, :failed, "the TLS handshake with #{elsewhere} failed (bad_certificate)."}

      assert SignInImpl.provider(elsewhere, []) == bad_certificate

      assert HTTPImpl.request(:get, elsewhere, "credential", nil, ca: {"staging", File.read!(ca)}) ==
               bad_certificate
    end

    test "without it, the certificate is not trusted, and the error says what to do", %{
      issuer: issuer
    } do
      assert SignInImpl.provider(issuer, []) ==
               {:error, :failed,
                "the TLS handshake with #{issuer} failed (unknown_ca). If its CA is the " <>
                  "installation's own, as a server's or a local EHOS's is, sign in with " <>
                  "EHOSCTL_CA_FILE set to that CA's certificate: ehosctl login keeps it for the " <>
                  "installation."}
    end

    test "with the kept CA another, the error names it and says to sign in again", %{
      issuer: issuer,
      other: other
    } do
      opts = [ca: {"staging", File.read!(other)}]

      for result <- [
            SignInImpl.provider(issuer, opts),
            HTTPImpl.request(:get, issuer, "credential", nil, opts)
          ] do
        assert result ==
                 {:error, :failed,
                  "the TLS handshake with #{issuer} failed (unknown_ca). The CA ehosctl keeps " <>
                    "for staging did not sign its certificate, and no CA this machine trusts " <>
                    "did. If the installation's CA changed, sign in to staging again with " <>
                    "EHOSCTL_CA_FILE set to the new one."}
      end

      stub_env(%{"EHOSCTL_CA_FILE" => other})

      assert SignInImpl.provider(issuer, opts) ==
               {:error, :failed,
                "the TLS handshake with #{issuer} failed (unknown_ca). Neither the CA in " <>
                  "EHOSCTL_CA_FILE=#{other} nor the CA ehosctl keeps for staging signed its " <>
                  "certificate, and no CA this machine trusts did. If the installation's CA " <>
                  "changed, sign in to staging again with EHOSCTL_CA_FILE set to the new one."}
    end

    test "a host that is no installation's gets no advice about an installation's CA", %{
      issuer: issuer
    } do
      assert HTTP.untrusted("https://api.github.com", {:tls_alert, {:unknown_ca, ~c"x"}}, nil) ==
               {:error, :failed,
                "the TLS handshake with https://api.github.com failed (unknown_ca)."}

      assert HTTPImpl.get(issuer, [], max_bytes: 1024, installation?: false) ==
               {:error, :failed, "the TLS handshake with #{issuer} failed (unknown_ca)."}
    end

    test "a kept CA with no certificate in it is refused, naming the installation", %{
      issuer: issuer
    } do
      assert SignInImpl.provider(issuer, ca: {"staging", "not a certificate"}) ==
               {:error, :failed,
                "the CA ehosctl keeps for staging holds no certificate it can read; sign in to " <>
                  "staging again with EHOSCTL_CA_FILE set to the installation's CA"}
    end

    test "ca_file_pem/1 refuses certificates that, encoded again, outgrow what is kept", %{
      tmp_dir: dir
    } do
      %{cert: der} = :public_key.pkix_test_root_cert(~c"EHOS CA", [])
      one_line = "-----BEGIN CERTIFICATE-----\n#{Base.encode64(der)}\n-----END CERTIFICATE-----\n"
      wrapped = :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
      count = div(1_048_576, byte_size(one_line))
      assert count * byte_size(wrapped) > 1_048_576

      bundle = Path.join(dir, "bundle.pem")
      File.write!(bundle, String.duplicate(one_line, count))

      assert Ehosctl.TLS.ca_file_pem(%{"EHOSCTL_CA_FILE" => bundle}) ==
               {:error, :invalid,
                "EHOSCTL_CA_FILE=#{bundle} holds more certificates than ehosctl keeps for an " <>
                  "installation (1048576 bytes)"}
    end

    test "with it naming another CA, the error says that CA did not sign the certificate", %{
      issuer: issuer,
      other: other
    } do
      stub_env(%{"EHOSCTL_CA_FILE" => other})

      for result <- [
            SignInImpl.provider(issuer, []),
            HTTPImpl.request(:get, issuer, "credential", nil, [])
          ] do
        assert result ==
                 {:error, :failed,
                  "the TLS handshake with #{issuer} failed (unknown_ca). The CA in " <>
                    "EHOSCTL_CA_FILE=#{other} did not sign its certificate, and no CA this " <>
                    "machine trusts did."}
      end
    end

    test "a file that cannot be read is an invalid input, named", %{
      issuer: issuer,
      tmp_dir: dir
    } do
      missing = Path.join(dir, "none.pem")
      stub_env(%{"EHOSCTL_CA_FILE" => missing})

      assert {:error, :invalid, message} = SignInImpl.provider(issuer, [])

      assert message == "cannot read EHOSCTL_CA_FILE=#{missing}: no such file or directory"
    end

    test "a file with one certificate that cannot be decoded is refused, though another does",
         %{issuer: issuer, ca: ca, tmp_dir: dir} do
      mixed = Path.join(dir, "mixed.pem")

      File.write!(
        mixed,
        File.read!(ca) <> "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"
      )

      stub_env(%{"EHOSCTL_CA_FILE" => mixed})

      assert SignInImpl.provider(issuer, []) ==
               {:error, :invalid,
                "EHOSCTL_CA_FILE=#{mixed} holds a certificate ehosctl cannot read"}
    end

    test "a path that is not a regular file, or a file larger than a CA bundle, is refused " <>
           "unread",
         %{issuer: issuer, tmp_dir: dir} do
      large = Path.join(dir, "large.pem")
      File.write!(large, :binary.copy("-", 1_048_577))

      stub_env(%{"EHOSCTL_CA_FILE" => large})

      assert SignInImpl.provider(issuer, []) ==
               {:error, :invalid,
                "EHOSCTL_CA_FILE=#{large} is larger than 1048576 bytes, more than a CA bundle is"}

      stub_env(%{"EHOSCTL_CA_FILE" => dir})

      assert SignInImpl.provider(issuer, []) ==
               {:error, :invalid, "EHOSCTL_CA_FILE=#{dir} is not a regular file"}
    end

    test "a path that would break the line it is said on is shown quoted", %{
      issuer: issuer,
      tmp_dir: dir
    } do
      missing = Path.join(dir, "ca\n.pem")
      stub_env(%{"EHOSCTL_CA_FILE" => missing})

      assert SignInImpl.provider(issuer, []) ==
               {:error, :invalid,
                "cannot read EHOSCTL_CA_FILE=#{inspect(missing)}: no such file or directory"}
    end

    test "a file with no certificate ehosctl can decode is named, before any connection, " <>
           "and :ssl logs nothing",
         %{issuer: issuer, tmp_dir: dir} do
      empty = Path.join(dir, "empty.pem")
      File.write!(empty, "not a certificate")

      # What an older test of eh-os left as its k3d cluster's CA: a PEM block whose DER is three
      # bytes, which `:public_key.pem_decode/1` reads and no certificate decoder does.
      placeholder = Path.join(dir, "ca.crt")
      File.write!(placeholder, "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n")

      for file <- [empty, placeholder] do
        stub_env(%{"EHOSCTL_CA_FILE" => file})

        log =
          capture_log(fn ->
            for result <- [
                  SignInImpl.provider(issuer, []),
                  HTTPImpl.request(:get, issuer, "credential", nil, [])
                ] do
              assert result ==
                       {:error, :invalid,
                        "EHOSCTL_CA_FILE=#{file} holds no certificate ehosctl can read"}
            end
          end)

        assert log == ""
      end
    end
  end

  describe "talking to EHOS's provider" do
    setup do
      # `SignIn.authorization/2` builds the URL through the implementation the configuration
      # chose, here the real one.
      Hammox.stub(Ehosctl.SignInMock, :redirect_url, &SignInImpl.redirect_url/2)
      %{issuer: FakeIssuer.start()}
    end

    test "the fake provider listens on this machine alone", %{issuer: issuer} do
      assert :ranch.get_addr(issuer.ref) == {{127, 0, 0, 1}, URI.parse(issuer.issuer).port}
    end

    test "exchange redeems the code with its verifier, as the public client ehosctl", %{
      issuer: issuer
    } do
      {provider, code, request} = authorized(issuer)

      # The credential and the refresh token are random, and the ID token is dated by the real
      # clock, which oidcc checks it against.
      assert {:ok,
              %{
                credential: "credential-" <> _,
                expires_in: 600,
                refresh_token: refresh,
                claims: %{"iat" => issued_at, "auth_time" => auth_time} = claims
              }} = SignInImpl.exchange(provider, code, request)

      assert claims == %{
               "iss" => issuer.issuer,
               "sub" => "0b9f6c1e-person",
               "aud" => "ehosctl",
               "email" => "grace@example.com",
               "nonce" => request.nonce,
               "iat" => issued_at,
               "exp" => issued_at + 600,
               "auth_time" => auth_time
             }

      assert FakeIssuer.refresh_tokens(issuer) == MapSet.new([refresh])

      # No client secret or assertion: ehosctl is a public client.
      assert FakeIssuer.requests(issuer, "/oauth/token") == [
               %{
                 "grant_type" => "authorization_code",
                 "client_id" => "ehosctl",
                 "code" => code,
                 "redirect_uri" => request.redirect_uri,
                 "code_verifier" => request.verifier
               }
             ]
    end

    test "discovered_endpoints reads the token endpoint, and refuses an address that is plain HTTP",
         %{issuer: issuer} do
      {:ok, request_opts} = Ehosctl.TLS.request_opts(issuer.issuer, %{}, {"local", issuer.ca})

      assert SignInImpl.discovered_endpoints(issuer.issuer, FakeIssuer.opts(issuer)) ==
               {:ok,
                %{
                  issuer: issuer.issuer,
                  token: issuer.issuer <> "/oauth/token",
                  revocation: issuer.issuer <> "/oauth/revoke",
                  request_opts: request_opts
                }}

      plain = String.replace(issuer.issuer, "https:", "http:")

      assert SignInImpl.discovered_endpoints(plain, FakeIssuer.opts(issuer)) ==
               {:error, :invalid,
                "#{plain} is plain HTTP; EHOS signs people in over https only; sign in with its " <>
                  "https address: ehosctl login URL"}
    end

    test "renew names the resource, as the public client, and returns the rotated token", %{
      issuer: issuer
    } do
      refresh = FakeIssuer.issue_refresh_token(issuer)

      assert {:ok,
              %{
                credential: "credential-" <> _,
                expires_in: 600,
                refresh_token: rotated,
                claims: claims
              }} = SignInImpl.renew(endpoints(issuer), refresh, "https://ledger.example.com")

      assert claims == %{}
      assert FakeIssuer.refresh_tokens(issuer) == MapSet.new([rotated])

      assert [renewal] = FakeIssuer.requests(issuer, "/oauth/token")

      assert renewal == %{
               "grant_type" => "refresh_token",
               "client_id" => "ehosctl",
               "refresh_token" => refresh,
               "resource" => "https://ledger.example.com"
             }
    end

    test "renew keeps the rotated token from an answer without an ID token", %{issuer: issuer} do
      FakeIssuer.renew_without_id_token(issuer)
      refresh = FakeIssuer.issue_refresh_token(issuer)

      assert {:ok,
              %{
                credential: "credential-" <> _,
                expires_in: 600,
                refresh_token: rotated,
                claims: claims
              }} = SignInImpl.renew(endpoints(issuer), refresh, issuer.issuer)

      assert claims == %{}

      assert FakeIssuer.refresh_tokens(issuer) == MapSet.new([rotated])
    end

    test "renew takes a credential's lifetime out of range as ten minutes", %{issuer: issuer} do
      FakeIssuer.answer_token(issuer, 200, %{
        "access_token" => "c",
        "refresh_token" => "r",
        "expires_in" => -5
      })

      assert SignInImpl.renew(endpoints(issuer), "refresh", issuer.issuer) ==
               {:ok, %{credential: "c", expires_in: 600, refresh_token: "r", claims: %{}}}
    end

    test "revoke posts the token as the public client, and ends it", %{issuer: issuer} do
      refresh = FakeIssuer.issue_refresh_token(issuer)

      assert SignInImpl.revoke(endpoints(issuer), refresh) == :ok

      assert FakeIssuer.requests(issuer, "/oauth/revoke") == [
               %{"client_id" => "ehosctl", "token" => refresh}
             ]

      assert FakeIssuer.refresh_tokens(issuer) == MapSet.new()
    end

    test "exchange refuses an ID token for another nonce", %{issuer: issuer} do
      FakeIssuer.put_id_token_claims(issuer, %{"nonce" => "another"})
      {provider, code, request} = authorized(issuer)

      assert SignInImpl.exchange(provider, code, request) ==
               {:error, :failed,
                "#{issuer.issuer}'s answer did not pass a sign-in's checks (missing_claim)"}
    end

    test "exchange refuses an ID token signed by a key EHOS does not publish", %{issuer: issuer} do
      FakeIssuer.sign_with_another_key(issuer)
      {provider, code, request} = authorized(issuer)

      assert SignInImpl.exchange(provider, code, request) ==
               {:error, :failed,
                "#{issuer.issuer}'s answer did not pass a sign-in's checks (no_matching_key)"}
    end

    test "provider refuses one whose endpoints are elsewhere than its issuer", %{issuer: issuer} do
      url = issuer.issuer

      for {field, endpoint} <- [
            {"authorization_endpoint", "https://evil.example.com/oauth/authorize"},
            {"token_endpoint", String.replace(url, "localhost", "127.0.0.1") <> "/t"},
            {"revocation_endpoint", "https://ehos.example.com\e[2J/oauth/revoke"},
            {"pushed_authorization_request_endpoint", "https://evil.example.com/oauth/par"},
            # A browser reads a backslash as a slash: this is evil.example to it.
            {"authorization_endpoint",
             String.replace(url, "//", "//evil.example\\@") <> "/oauth/authorize"}
          ] do
        FakeIssuer.put_discovery(issuer, %{field => endpoint})

        assert SignInImpl.provider(url, FakeIssuer.opts(issuer)) ==
                 {:error, :failed,
                  "#{url} names an endpoint that is not https on #{url} itself; " <>
                    "ehosctl does not sign in there"},
               field
      end
    end

    test "authorization pushes the request to the endpoint discovery names for it, trusting " <>
           "the installation's CA",
         %{issuer: issuer} do
      FakeIssuer.put_discovery(issuer, %{
        "pushed_authorization_request_endpoint" => issuer.issuer <> "/oauth/par"
      })

      {:ok, provider} = SignInImpl.provider(issuer.issuer, FakeIssuer.opts(issuer))
      {:ok, url, request} = SignIn.authorization(provider, "http://127.0.0.1:1/callback")

      assert URI.decode_query(URI.parse(url).query) == %{
               "client_id" => "ehosctl",
               "request_uri" => "urn:ietf:params:oauth:request_uri:pushed"
             }

      # The challenge is the verifier's, which is random; the verifier itself is never sent.
      assert [pushed] = FakeIssuer.requests(issuer, "/oauth/par")

      assert Map.delete(pushed, "code_challenge") == %{
               "client_id" => "ehosctl",
               "response_type" => "code",
               "redirect_uri" => "http://127.0.0.1:1/callback",
               "scope" => "openid email",
               "state" => request.state,
               "nonce" => request.nonce,
               "code_challenge_method" => "S256",
               "max_age" => "0"
             }

      assert pushed["code_challenge"] ==
               Base.url_encode64(:crypto.hash(:sha256, request.verifier), padding: false)
    end

    test "authorization says why a pushed authorization request failed", %{issuer: issuer} do
      url = issuer.issuer

      FakeIssuer.put_discovery(issuer, %{
        "pushed_authorization_request_endpoint" => url <> "/oauth/par"
      })

      {:ok, provider} = SignInImpl.provider(url, FakeIssuer.opts(issuer))
      authorization = fn -> SignIn.authorization(provider, "http://127.0.0.1:1/callback") end

      FakeIssuer.answer_push(issuer, 503, %{})

      assert authorization.() ==
               {:error, :unreachable, "#{url} is unavailable (HTTP 503). Try again later."}

      for {status, body, said} <- [
            {400, %{"error" => "invalid_request"}, ": invalid_request"},
            # The token endpoint's code, which would read as an expired sign-in there.
            {400, %{"error" => "invalid_grant"}, ": invalid_grant"},
            {201, %{"expires_in" => 60}, ""}
          ] do
        FakeIssuer.answer_push(issuer, status, body)

        assert authorization.() ==
                 {:error, :failed,
                  "#{url} did not take the pushed authorization request (HTTP #{status})" <> said}
      end

      {:error, :failed, "#{url} refused the request (HTTP 400): invalid_request"}

      FakeIssuer.down(issuer)
      assert authorization.() == {:error, :unreachable, "#{url} did not answer."}
    end

    test "oidcc's requests follow no redirect: a pushed authorization request redirected to " <>
           "the token endpoint goes no further",
         %{issuer: issuer} do
      url = issuer.issuer
      # `/oauth/moved` answers 308 to the token endpoint.
      FakeIssuer.put_discovery(issuer, %{
        "pushed_authorization_request_endpoint" => url <> "/oauth/moved"
      })

      {:ok, provider} = SignInImpl.provider(url, FakeIssuer.opts(issuer))

      assert SignIn.authorization(provider, "http://127.0.0.1:1/callback") ==
               {:error, :failed,
                "#{url} redirected a request of the sign-in (HTTP 308); ehosctl did not follow"}

      assert FakeIssuer.requests(issuer, "/oauth/token") == []
    end

    test "exchange follows no redirect: a code posted to an endpoint that redirects to the " <>
           "token endpoint goes no further",
         %{issuer: issuer} do
      {provider, code, request} = authorized(issuer)
      # `/oauth/moved` answers 308 to the token endpoint.
      configuration = %{
        provider.context.provider_configuration
        | token_endpoint: issuer.issuer <> "/oauth/moved"
      }

      provider = put_in(provider.context.provider_configuration, configuration)

      assert SignInImpl.exchange(provider, code, request) ==
               {:error, :failed,
                "#{issuer.issuer} redirected a request of the sign-in (HTTP 308); ehosctl did " <>
                  "not follow"}

      assert FakeIssuer.requests(issuer, "/oauth/token") == []
    end

    test "provider refuses an address whose discovery names another issuer", %{issuer: issuer} do
      url = String.replace(issuer.issuer, "localhost", "127.0.0.1")

      assert SignInImpl.provider(url, FakeIssuer.opts(issuer)) ==
               {:error, :failed,
                "#{url} names #{issuer.issuer} as its issuer; sign in with that address"}
    end

    test "says when EHOS does not answer", %{issuer: issuer} do
      endpoints = endpoints(issuer)
      FakeIssuer.down(issuer)
      did_not_answer = {:error, :unreachable, "#{issuer.issuer} did not answer."}

      assert SignInImpl.provider(issuer.issuer, FakeIssuer.opts(issuer)) == did_not_answer
      assert SignInImpl.renew(endpoints, "refresh", issuer.issuer) == did_not_answer
      assert SignInImpl.revoke(endpoints, "refresh") == did_not_answer
    end

    test "renew says what each answer EHOS gives means", %{issuer: issuer} do
      url = issuer.issuer
      nothing_granted = {:error, :refused, Ehosctl.Refusal.sentence("no_capability")}

      for {status, body, result} <- [
            {307, %{}, {:error, :redirected}},
            {404, %{}, {:error, :moved}},
            {400, %{"error" => "invalid_grant"},
             {:error, :not_signed_in, "Your sign-in has expired. Run `ehosctl login`."}},
            {400, %{"error" => "invalid_target"}, nothing_granted},
            {400, %{"error" => "no_capability"}, nothing_granted},
            {401, %{"error" => "no_keys"},
             {:error, :failed, "#{url} refused the request (HTTP 401): no_keys"}},
            {429, %{"error" => "slow_down"},
             {:error, :unreachable, "Too many calls in the last minute. Try again in a minute."}},
            {403,
             %{
               "error" => "no_console",
               "error_description" => "this account may not\e[2J use EHOS's console or terminal"
             },
             {:error, :refused,
              "#{url} refused the request (HTTP 403): no_console: " <>
                "this account may not[2J use EHOS's console or terminal"}},
            {200, %{"access_token" => "c"},
             {:error, :failed, "EHOS's answer lacked a credential or a refresh token"}}
          ] do
        FakeIssuer.answer_token(issuer, status, body)

        assert SignInImpl.renew(endpoints(issuer), "refresh", url) == result,
               "#{status} #{inspect(body)}"
      end
    end

    test "revoke says an endpoint that is gone, redirects or is not named", %{issuer: issuer} do
      endpoints = endpoints(issuer)

      for {status, result} <- [{307, {:error, :redirected}}, {410, {:error, :moved}}] do
        FakeIssuer.answer_revoke(issuer, status, %{})
        assert SignInImpl.revoke(endpoints, "refresh") == result, "#{status}"
      end

      assert SignInImpl.revoke(%{endpoints | revocation: nil}, "refresh") == {:error, :moved}
    end
  end

  describe "callback/3" do
    test "gives the code of this request, from this issuer" do
      params = %{"state" => "the-state", "iss" => @issuer, "code" => "c"}
      assert SignIn.callback(params, @request, @issuer) == {:ok, "c"}
    end

    test "passes over another request's answer" do
      assert SignIn.callback(
               %{"state" => "other", "iss" => @issuer, "code" => "c"},
               @request,
               @issuer
             ) ==
               :ignore

      assert SignIn.callback(%{"iss" => @issuer, "code" => "c"}, @request, @issuer) == :ignore
    end

    test "refuses an answer from another issuer, or naming none" do
      for iss <- ["https://evil.example.com", nil] do
        params = %{"state" => "the-state", "iss" => iss, "code" => "c"}

        assert SignIn.callback(params, @request, @issuer) ==
                 {:error, :failed, "the answer to this sign-in did not come from #{@issuer}"}
      end
    end

    test "an error EHOS sent back is a refusal, printed safely" do
      params = %{"state" => "the-state", "iss" => @issuer, "error" => "access_denied\e[2J"}

      assert SignIn.callback(params, @request, @issuer) ==
               {:error, :refused, ~S|EHOS did not sign you in ("access_denied\e[2J")|}
    end

    test "an error EHOS sent back shows its reason after its code" do
      params = %{
        "state" => "the-state",
        "iss" => @issuer,
        "error" => "access_denied",
        "error_description" => "this account may not use EHOS's console or terminal"
      }

      assert SignIn.callback(params, @request, @issuer) ==
               {:error, :refused,
                "EHOS did not sign you in (access_denied): " <>
                  "this account may not use EHOS's console or terminal"}

      for description <- [nil, "", " \e "] do
        params = Map.put(params, "error_description", description)

        assert SignIn.callback(params, @request, @issuer) ==
                 {:error, :refused, "EHOS did not sign you in (access_denied)"}
      end
    end

    test "an error's reason is shown without control characters and bounded in length" do
      params = %{
        "state" => "the-state",
        "iss" => @issuer,
        "error" => "access_denied",
        "error_description" =>
          "not\e[2J allowed\u202E\n" <> String.duplicate("a", 500) <> <<0xFF>>
      }

      # 200 characters, the last of them the ellipsis.
      reason = "not[2J allowed " <> String.duplicate("a", 184) <> "…"

      assert SignIn.callback(params, @request, @issuer) ==
               {:error, :refused, "EHOS did not sign you in (access_denied): " <> reason}

      assert Ehosctl.Output.printable?(reason)
    end

    test "an error's reason keeps its joiners, and is bounded in code points" do
      params = %{
        "state" => "the-state",
        "iss" => @issuer,
        "error" => "access_denied",
        "error_description" =>
          "مي\u200Cخواهم \uFFFF" <> "a" <> String.duplicate("\u0301", 10_000) <> " b"
      }

      # 200 code points, the last of them the ellipsis.
      reason = "مي\u200Cخواهم a" <> String.duplicate("\u0301", 189) <> "…"

      assert SignIn.callback(params, @request, @issuer) ==
               {:error, :refused, "EHOS did not sign you in (access_denied): " <> reason}

      assert Ehosctl.Output.shown_lines(reason) == reason
    end

    test "an error's reason is cut at a word's end, not before a space" do
      params = %{
        "state" => "the-state",
        "iss" => @issuer,
        "error" => "access_denied",
        "error_description" => String.duplicate("a", 198) <> " " <> String.duplicate("b", 10)
      }

      assert SignIn.callback(params, @request, @issuer) ==
               {:error, :refused,
                "EHOS did not sign you in (access_denied): " <> String.duplicate("a", 198) <> "…"}
    end

    test "an error's reason is shown on one line, its words kept apart" do
      params = %{
        "state" => "the-state",
        "iss" => @issuer,
        "error" => "access_denied",
        "error_description" => "this account\nmay not\t\tuse\u2028EHOS \e or\u200B \u202Ethis"
      }

      assert SignIn.callback(params, @request, @issuer) ==
               {:error, :refused,
                "EHOS did not sign you in (access_denied): " <>
                  "this account may not use EHOS or this"}
    end
  end

  describe "the page" do
    # The page writes the outcome's markup itself: a class the design system renamed would leave
    # it unstyled, so every class it uses must be one the stylesheets it carries define.
    test "uses only classes the design system defines" do
      html =
        %{tone: :error, title: "t", text: "x", hint: "h"}
        |> Ehosctl.SignIn.Page.render()
        |> IO.iodata_to_binary()

      [styles, body] = String.split(html, "</style>", parts: 2)

      classes =
        ~r/class="([^"]+)"/
        |> Regex.scan(body, capture: :all_but_first)
        |> Enum.flat_map(&String.split(hd(&1)))
        |> Enum.uniq()

      assert classes == [
               "eh-outcome-page",
               "eh-ambient",
               "eh-outcome-header",
               "eh-outcome",
               "eh-outcome-mark",
               "eh-outcome-title",
               "eh-outcome-text",
               "eh-outcome-hint"
             ]

      for class <- classes do
        # The whole name: `.eh-outcome-title` is not `.eh-outcome`.
        assert Regex.match?(~r/\.#{Regex.escape(class)}(?![\w-])/, styles), class
      end

      assert body == """

             <title>t · ehosctl</title>
             </head>
             <body class="eh-outcome-page eh-ambient">
             <header class="eh-outcome-header">EHOS · ehosctl</header>
             <main>
             <div class="eh-outcome" data-kind="error" role="status">
             <span class="eh-outcome-mark" aria-hidden="true"></span>
             <h1 class="eh-outcome-title">t</h1>
             <p class="eh-outcome-text">x</p>
             <p class="eh-outcome-hint">h</p>
             </div>
             </main>
             </body>
             </html>
             """

      # The stylesheets are the design system's, whole: the line the page's kind needs is read.
      assert styles =~ ~s(.eh-outcome[data-kind="error"])
    end
  end

  describe "the loopback listener" do
    test "answers another path with a 404 and waits on for the callback" do
      {:ok, listener} = Loopback.open()
      uri = Loopback.redirect_uri(listener)
      assert uri =~ ~r{\Ahttp://127\.0\.0\.1:\d+/callback\z}
      base = String.replace_suffix(uri, "/callback", "")

      waiting =
        Task.async(fn ->
          Loopback.await(listener, 5_000, fn params ->
            {:done, params, %{tone: :ok, title: "Done", text: "Done."}}
          end)
        end)

      assert :httpc.request(String.to_charlist(base <> "/favicon.ico")) ==
               {:ok,
                {{~c"HTTP/1.1", 404, ~c"Not Found"}, loopback_headers(~c"text/plain", 10),
                 ~c"Not found."}}

      {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, headers, body}} =
        :httpc.request(String.to_charlist(uri <> "?code=c&state=s"))

      assert Task.await(waiting) == {:ok, %{"code" => "c", "state" => "s"}}

      body = :erlang.list_to_binary(body)
      assert body == done_page()
      assert headers == loopback_headers(~c"text/html", byte_size(done_page()))

      # In the design system, which the page carries whole: nothing is loaded from elsewhere. The
      # page holds its fonts, so what it is made of is read, not the page whole.
      assert body =~ "--canvas:"
      assert body =~ ".eh-outcome-mark"
      assert body =~ ~s(class="eh-outcome")
      assert body =~ ~s{font-family: "Albert Sans"}
      assert body =~ "data:font/woff2;base64,"
      refute body =~ ~r{(src|href)="https?:}
      refute body =~ ~s{url("/}

      Loopback.close(listener)
    end

    # Ended by the clock alone, as it would otherwise wait the whole minute and fail.
    @tag timeout: 5_000
    test "ends its wait by Ehosctl.Clock" do
      {:ok, listener} = Loopback.open()
      # The deadline is read at 0, and every reading after it is a minute on.
      {:ok, next} = Agent.start_link(fn -> 0 end)
      stub(Ehosctl.ClockMock, :monotonic, fn -> Agent.get_and_update(next, &{&1, 60_000}) end)

      assert Loopback.await(listener, 60_000, fn _params -> flunk("no request was sent") end) ==
               {:error, :timeout}

      Loopback.close(listener)
    end

    @tag timeout: 5_000
    test "serves nothing queued after its deadline" do
      {:ok, listener} = Loopback.open()
      %URI{port: port} = URI.parse(Loopback.redirect_uri(listener))
      # A callback, whole, already waiting when the deadline has passed.
      {:ok, late} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
      :ok = :gen_tcp.send(late, "GET /callback?code=c HTTP/1.1\r\n\r\n")
      {:ok, next} = Agent.start_link(fn -> 0 end)
      stub(Ehosctl.ClockMock, :monotonic, fn -> Agent.get_and_update(next, &{&1, 60_000}) end)

      assert Loopback.await(listener, 60_000, fn _params -> flunk("it was served") end) ==
               {:error, :timeout}

      :gen_tcp.close(late)
      Loopback.close(listener)
    end

    test "a connection held open does not keep the callback waiting" do
      {:ok, listener} = Loopback.open()
      uri = Loopback.redirect_uri(listener)
      %URI{port: port} = URI.parse(uri)
      started = System.monotonic_time(:millisecond)
      # A clock sixteen times as fast as the real one, so a request's five seconds, which are
      # real sockets' timeouts, pass in about 300 milliseconds, and a minute's wait for the next
      # connection in about four seconds: long enough for a held connection to show past the
      # 1.5 seconds below.
      stub(Ehosctl.ClockMock, :monotonic, fn ->
        (System.monotonic_time(:millisecond) - started) * 16
      end)

      waiting =
        Task.async(fn ->
          Loopback.await(listener, 60_000, fn params ->
            {:done, params, %{tone: :ok, title: "Done", text: "Done."}}
          end)
        end)

      # A local process that sends a header every 100 milliseconds, for two seconds.
      {:ok, slow} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
      :ok = :gen_tcp.send(slow, "GET /callback?state=x HTTP/1.1\r\n")

      trickle =
        Task.async(fn ->
          for n <- 1..20 do
            Process.sleep(100)
            :gen_tcp.send(slow, "x-#{n}: y\r\n")
          end
        end)

      assert :httpc.request(String.to_charlist(uri <> "?code=c")) ==
               {:ok,
                {{~c"HTTP/1.1", 200, ~c"OK"},
                 loopback_headers(~c"text/html", byte_size(done_page())),
                 :erlang.binary_to_list(done_page())}}

      assert Task.await(waiting) == {:ok, %{"code" => "c"}}
      assert System.monotonic_time(:millisecond) - started < 1_500

      Task.await(trickle)
      Loopback.close(listener)
    end

    test "takes a request with 100 headers, not one with 101" do
      {:ok, listener} = Loopback.open()
      %URI{port: port} = URI.parse(Loopback.redirect_uri(listener))

      waiting =
        Task.async(fn ->
          Loopback.await(listener, 5_000, fn params ->
            {:done, params, %{tone: :ok, title: "Done", text: "Done."}}
          end)
        end)

      for {count, code} <- [{101, "too-many"}, {100, "c"}] do
        {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
        headers = for n <- 1..count, do: "x-#{n}: y\r\n"
        :ok = :gen_tcp.send(socket, ["GET /callback?code=#{code} HTTP/1.1\r\n", headers, "\r\n"])
        _ = :gen_tcp.recv(socket, 0, 2_000)
        :gen_tcp.close(socket)
      end

      assert Task.await(waiting) == {:ok, %{"code" => "c"}}
      Loopback.close(listener)
    end

    test "gives up after its timeout" do
      {:ok, listener} = Loopback.open()

      assert Loopback.await(listener, 50, fn _ ->
               {:done, :x, %{tone: :ok, title: "", text: ""}}
             end) == {:error, :timeout}

      Loopback.close(listener)
    end
  end

  # A provider read from `issuer`, and the code it gave a sign-in that asked for one.
  defp authorized(issuer) do
    {:ok, provider} = SignInImpl.provider(issuer.issuer, FakeIssuer.opts(issuer))
    {:ok, url, request} = SignIn.authorization(provider, "http://127.0.0.1:1/callback")
    {provider, FakeIssuer.authorize(issuer, url), request}
  end

  defp endpoints(issuer) do
    {:ok, endpoints} = SignInImpl.discovered_endpoints(issuer.issuer, FakeIssuer.opts(issuer))
    endpoints
  end

  defp no_discovery(issuer),
    do:
      {:error, :failed, "#{issuer} is not an installation of EHOS: it has no discovery document"}

  # What `Ehosctl.HTTPImpl` gives of the 404 `serve/1` answers.
  defp not_found,
    do:
      {:ok,
       %{status: 404, headers: %{"connection" => "close", "content-length" => "0"}, body: nil}}

  # The page a callback answered `{:done, _, %{tone: :ok, title: "Done", text: "Done."}}` gets.
  defp done_page,
    do:
      IO.iodata_to_binary(Ehosctl.SignIn.Page.render(%{tone: :ok, title: "Done", text: "Done."}))

  # The headers the loopback listener answers with, as `:httpc` gives them.
  defp loopback_headers(type, length) do
    [
      {~c"cache-control", ~c"no-store"},
      {~c"connection", ~c"close"},
      {~c"content-length", Integer.to_charlist(length)},
      {~c"content-type", type ++ ~c"; charset=utf-8"},
      {~c"referrer-policy", ~c"no-referrer"},
      {~c"content-security-policy",
       ~c"default-src 'none'; style-src 'unsafe-inline'; font-src data:; " ++
         ~c"base-uri 'none'; form-action 'none'"}
    ]
  end

  # Answers every request on `listener` with a 404, as an address with no discovery document does.
  defp serve(listener) do
    with {:ok, socket} <- :ssl.transport_accept(listener),
         {:ok, socket} <- :ssl.handshake(socket, 5_000) do
      {:ok, _request} = :ssl.recv(socket, 0, 5_000)

      :ssl.send(
        socket,
        "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
      )

      :ssl.close(socket)
    end

    serve(listener)
  end
end
