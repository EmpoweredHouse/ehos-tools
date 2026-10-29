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

  describe "origin/1" do
    test "keeps an origin, lowercased, without a trailing slash" do
      assert SignIn.origin("https://ehos.example.com") == {:ok, "https://ehos.example.com"}

      assert SignIn.origin("https://ehos.example.com:8443/") ==
               {:ok, "https://ehos.example.com:8443"}
    end

    test "refuses plain HTTP, even on this machine, but for the tests' fake EHOS" do
      for url <- ~w(http://ehos.example.com http://localhost:4000 http://127.0.0.1:4000) do
        assert {:error, :invalid, message} = SignIn.origin(url)
        assert message =~ "is plain HTTP; EHOS signs people in over https only"
      end

      assert SignIn.origin("http://localhost:4000", allow_http: true) ==
               {:ok, "http://localhost:4000"}
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
        assert {:error, :invalid, _} = SignIn.origin(url), inspect(url)
      end
    end
  end

  describe "EHOSCTL_CA_FILE" do
    @describetag :tmp_dir

    # An https server on a local port, with a certificate for localhost from a CA of its own,
    # which answers every request with a 404, as an address with no discovery document does.
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
        :ssl.listen(0, server ++ [active: false, reuseaddr: true, log_level: :none])

      {:ok, {_address, port}} = :ssl.sockname(listener)
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

    test "a certificate from the CA it names is trusted", %{issuer: issuer, ca: ca} do
      stub_env(%{"EHOSCTL_CA_FILE" => ca})

      assert {:error, :failed, message} = SignInImpl.provider(issuer, [])
      assert message =~ "has no discovery document"
    end

    test "without it, the certificate is not trusted, and the error says what to do", %{
      issuer: issuer
    } do
      assert {:error, :failed, message} = SignInImpl.provider(issuer, [])
      assert message =~ "the TLS handshake with #{issuer} failed (unknown_ca)"
      assert message =~ "sign in with EHOSCTL_CA_FILE set to that CA's certificate"
      assert message =~ "ehosctl login keeps it for the installation"
    end

    test "a certificate from the CA kept for the installation is trusted with no variable set",
         %{issuer: issuer, ca: ca} do
      opts = [ca: {"staging", File.read!(ca)}]

      assert {:error, :failed, message} = SignInImpl.provider(issuer, opts)
      assert message =~ "has no discovery document"
      assert {:ok, %{status: 404}} = HTTPImpl.request(:get, issuer, "credential", nil, opts)
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
        assert {:error, :failed, message} = result
        assert message =~ "The CA ehosctl keeps for staging did not sign its certificate"
        assert message =~ "sign in to staging again with EHOSCTL_CA_FILE set to the new one"
      end

      stub_env(%{"EHOSCTL_CA_FILE" => other})
      assert {:error, :failed, message} = SignInImpl.provider(issuer, opts)

      assert message =~
               "Neither the CA in EHOSCTL_CA_FILE=#{other} nor the CA ehosctl keeps for " <>
                 "staging signed its certificate"
    end

    test "a host that is no installation's gets no advice about an installation's CA", %{
      issuer: issuer
    } do
      assert {:error, :failed, message} =
               HTTP.untrusted("https://api.github.com", {:tls_alert, {:unknown_ca, ~c"x"}}, nil)

      assert message == "the TLS handshake with https://api.github.com failed (unknown_ca)."

      assert HTTPImpl.get(issuer, [], max_bytes: 1024, installation?: false) ==
               {:error, :failed, "the TLS handshake with #{issuer} failed (unknown_ca)."}
    end

    test "a kept CA with no certificate in it is refused, naming the installation", %{
      issuer: issuer
    } do
      assert {:error, :failed, message} =
               SignInImpl.provider(issuer, ca: {"staging", "not a certificate"})

      assert message =~ "the CA ehosctl keeps for staging holds no certificate it can read"
    end

    test "ca_file_pem/1 gives the file's certificates alone, encoded again", %{
      ca: ca,
      tmp_dir: dir
    } do
      noisy = Path.join(dir, "noisy.pem")
      File.write!(noisy, "a comment\n" <> File.read!(ca) <> "trailing words\n")

      assert Ehosctl.TLS.ca_file_pem(%{}) == {:ok, nil}
      assert Ehosctl.TLS.ca_file_pem(%{"EHOSCTL_CA_FILE" => ""}) == {:ok, nil}
      assert {:ok, pem} = Ehosctl.TLS.ca_file_pem(%{"EHOSCTL_CA_FILE" => noisy})
      assert pem == File.read!(ca)
      refute pem =~ "comment"

      assert {:error, :invalid, _} =
               Ehosctl.TLS.ca_file_pem(%{"EHOSCTL_CA_FILE" => Path.join(dir, "none.pem")})
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

      assert {:error, :invalid, message} = Ehosctl.TLS.ca_file_pem(%{"EHOSCTL_CA_FILE" => bundle})
      assert message =~ "holds more certificates than ehosctl keeps for an installation"
    end

    test "HTTP.request/5 trusts it too", %{issuer: issuer, ca: ca} do
      stub_env(%{"EHOSCTL_CA_FILE" => ca})

      assert {:ok, %{status: 404}} = HTTPImpl.request(:get, issuer, "credential", nil, [])
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
        assert {:error, :failed, message} = result
        assert message =~ "the TLS handshake with #{issuer} failed (unknown_ca)"
        assert message =~ "The CA in EHOSCTL_CA_FILE=#{other} did not sign its certificate"
        refute message =~ "set EHOSCTL_CA_FILE"
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

      assert {:error, :invalid, message} = SignInImpl.provider(issuer, [])

      assert message =~ "EHOSCTL_CA_FILE=#{inspect(missing)}"
      refute message =~ "\n"
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

        refute log =~ "SSL WARNING"
      end
    end
  end

  describe "talking to EHOS's provider" do
    setup do
      %{issuer: FakeIssuer.start()}
    end

    test "exchange redeems the code with its verifier, as the public client ehosctl", %{
      issuer: issuer
    } do
      {provider, code, request} = authorized(issuer)

      assert {:ok, tokens} = SignInImpl.exchange(provider, code, request)
      assert %{credential: "credential-" <> _, expires_in: 600, refresh_token: refresh} = tokens
      assert %{"sub" => "0b9f6c1e-person", "email" => "grace@example.com"} = tokens.claims
      assert FakeIssuer.refresh_tokens(issuer) == MapSet.new([refresh])

      assert [exchange] = FakeIssuer.requests(issuer, "/oauth/token")
      assert exchange["grant_type"] == "authorization_code"
      assert exchange["client_id"] == "ehosctl"
      assert exchange["redirect_uri"] == request.redirect_uri
      assert exchange["code_verifier"] == request.verifier
      refute Map.has_key?(exchange, "client_secret")
      refute Map.has_key?(exchange, "client_assertion")
    end

    test "exchange refuses an ID token for another nonce", %{issuer: issuer} do
      FakeIssuer.put_id_token_claims(issuer, %{"nonce" => "another"})
      {provider, code, request} = authorized(issuer)

      assert {:error, :failed, message} = SignInImpl.exchange(provider, code, request)
      assert message =~ "did not pass a sign-in's checks"
    end

    test "exchange refuses an ID token signed by a key EHOS does not publish", %{issuer: issuer} do
      FakeIssuer.sign_with_another_key(issuer)
      {provider, code, request} = authorized(issuer)

      assert {:error, :failed, message} = SignInImpl.exchange(provider, code, request)
      assert message =~ "did not pass a sign-in's checks"
    end

    test "provider refuses one whose endpoints are elsewhere than its issuer", %{issuer: issuer} do
      url = issuer.issuer

      for {field, endpoint} <- [
            {"authorization_endpoint", "https://evil.example.com/oauth/authorize"},
            {"token_endpoint", String.replace(url, "localhost", "127.0.0.1") <> "/t"},
            {"revocation_endpoint", "https://ehos.example.com\e[2J/oauth/revoke"},
            # A browser reads a backslash as a slash: this is evil.example to it.
            {"authorization_endpoint",
             String.replace(url, "//", "//evil.example\\@") <> "/oauth/authorize"}
          ] do
        FakeIssuer.put_discovery(issuer, %{field => endpoint})

        assert SignInImpl.provider(url, allow_http: true) ==
                 {:error, :failed,
                  "#{url} names an endpoint that is not https on #{url} itself; " <>
                    "ehosctl does not sign in there"},
               field
      end
    end

    test "provider refuses an address whose discovery names another issuer", %{issuer: issuer} do
      url = String.replace(issuer.issuer, "localhost", "127.0.0.1")

      assert {:error, :failed, message} = SignInImpl.provider(url, allow_http: true)
      assert message =~ "names #{issuer.issuer} as its issuer"
    end

    test "discovered_endpoints refuses an address that is plain HTTP, but for the tests", %{
      issuer: issuer
    } do
      assert {:ok, %{token: token}} =
               SignInImpl.discovered_endpoints(issuer.issuer, allow_http: true)

      assert token == issuer.issuer <> "/oauth/token"

      assert {:error, :invalid, message} = SignInImpl.discovered_endpoints(issuer.issuer, [])
      assert message =~ "is plain HTTP"
    end

    test "says when EHOS does not answer", %{issuer: issuer} do
      endpoints = endpoints(issuer)
      FakeIssuer.down(issuer)
      did_not_answer = {:error, :unreachable, "#{issuer.issuer} did not answer."}

      assert SignInImpl.provider(issuer.issuer, allow_http: true) == did_not_answer
      assert SignInImpl.renew(endpoints, "refresh", issuer.issuer) == did_not_answer
      assert SignInImpl.revoke(endpoints, "refresh") == did_not_answer
    end

    test "renew names the resource, as the public client, and returns the rotated token", %{
      issuer: issuer
    } do
      refresh = FakeIssuer.issue_refresh_token(issuer)

      assert {:ok, renewed} =
               SignInImpl.renew(endpoints(issuer), refresh, "https://ledger.example.com")

      assert %{credential: "credential-" <> _, expires_in: 600, claims: %{}} = renewed
      assert FakeIssuer.refresh_tokens(issuer) == MapSet.new([renewed.refresh_token])

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

      assert {:ok, %{refresh_token: rotated}} =
               SignInImpl.renew(endpoints(issuer), refresh, issuer.issuer)

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

    test "revoke posts the token as the public client, and ends it", %{issuer: issuer} do
      refresh = FakeIssuer.issue_refresh_token(issuer)

      assert SignInImpl.revoke(endpoints(issuer), refresh) == :ok

      assert FakeIssuer.requests(issuer, "/oauth/revoke") == [
               %{"client_id" => "ehosctl", "token" => refresh}
             ]

      assert FakeIssuer.refresh_tokens(issuer) == MapSet.new()
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

  # A provider read from `issuer`, and the code it gave a sign-in that asked for one.
  defp authorized(issuer) do
    {:ok, provider} = SignInImpl.provider(issuer.issuer, allow_http: true)
    {:ok, url, request} = SignIn.authorization(provider, "http://127.0.0.1:1/callback")
    {provider, FakeIssuer.authorize(issuer, url), request}
  end

  defp endpoints(issuer) do
    {:ok, endpoints} = SignInImpl.discovered_endpoints(issuer.issuer, allow_http: true)
    endpoints
  end

  describe "callback/3" do
    @request %{state: "the-state", nonce: "n", verifier: "v", redirect_uri: "r"}
    @issuer "https://ehos.example.com"

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
        assert {:error, :failed, _} = SignIn.callback(params, @request, @issuer)
      end
    end

    test "an error EHOS sent back is a refusal, printed safely" do
      params = %{"state" => "the-state", "iss" => @issuer, "error" => "access_denied\e[2J"}
      assert {:error, :refused, message} = SignIn.callback(params, @request, @issuer)
      refute message =~ "\e"
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

      assert {:error, :refused, "EHOS did not sign you in (access_denied): " <> reason} =
               SignIn.callback(params, @request, @issuer)

      assert String.starts_with?(reason, "not[2J allowed")
      assert String.length(reason) == 200
      assert String.ends_with?(reason, "a…")
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

      assert {:error, :refused, "EHOS did not sign you in (access_denied): " <> reason} =
               SignIn.callback(params, @request, @issuer)

      assert String.starts_with?(reason, "مي\u200Cخواهم a")
      assert length(String.codepoints(reason)) == 200
      assert Ehosctl.Output.shown_lines(reason) == reason
    end

    test "an error's reason is cut at a word's end, not before a space" do
      params = %{
        "state" => "the-state",
        "iss" => @issuer,
        "error" => "access_denied",
        "error_description" => String.duplicate("a", 198) <> " " <> String.duplicate("b", 10)
      }

      assert {:error, :refused, message} = SignIn.callback(params, @request, @issuer)
      assert String.ends_with?(message, String.duplicate("a", 198) <> "…")
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

      assert "eh-outcome" in classes

      for class <- classes do
        # The whole name: `.eh-outcome-title` is not `.eh-outcome`.
        assert Regex.match?(~r/\.#{Regex.escape(class)}(?![\w-])/, styles), class
      end

      assert body =~ ~s(data-kind="error")
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

      {:ok, {{_, 404, _}, _, _}} = :httpc.request(String.to_charlist(base <> "/favicon.ico"))

      {:ok, {{_, 200, _}, headers, body}} =
        :httpc.request(String.to_charlist(uri <> "?code=c&state=s"))

      assert Task.await(waiting) == {:ok, %{"code" => "c", "state" => "s"}}
      assert {~c"referrer-policy", ~c"no-referrer"} in headers
      assert to_string(body) =~ "Done."

      # In the design system, which the page carries whole: nothing is loaded from elsewhere.
      body = to_string(body)
      assert body =~ "--canvas:"
      assert body =~ ".eh-outcome-mark"
      assert body =~ ~s(class="eh-outcome")
      assert body =~ ~s{font-family: "Albert Sans"}
      assert body =~ "data:font/woff2;base64,"
      refute body =~ ~r{(src|href)="https?:}
      refute body =~ ~s{url("/}

      {~c"content-security-policy", csp} = List.keyfind(headers, ~c"content-security-policy", 0)
      assert to_string(csp) =~ "default-src 'none'"
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

      waiting =
        Task.async(fn ->
          Loopback.await(
            listener,
            10_000,
            fn params -> {:done, params, %{tone: :ok, title: "Done", text: "Done."}} end,
            request_timeout: 300
          )
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

      {:ok, {{_, 200, _}, _, _}} = :httpc.request(String.to_charlist(uri <> "?code=c"))
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
end
