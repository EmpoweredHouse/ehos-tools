defmodule Ehosctl.SignInTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Ehosctl.HTTP
  alias Ehosctl.SignIn
  alias Ehosctl.SignIn.Loopback

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
      assert {:error, :failed, message} =
               SignIn.provider(issuer, env: %{"EHOSCTL_CA_FILE" => ca})

      assert message =~ "has no discovery document"
    end

    test "without it, the certificate is not trusted, and the error says what to do", %{
      issuer: issuer
    } do
      assert {:error, :failed, message} = SignIn.provider(issuer, env: %{})
      assert message =~ "the TLS handshake with #{issuer} failed (unknown_ca)"
      assert message =~ "set EHOSCTL_CA_FILE to that CA's certificate"
    end

    test "HTTP.request/5 trusts it too", %{issuer: issuer, ca: ca} do
      assert {:ok, %{status: 404}} =
               HTTP.request(:get, issuer, "credential", nil, env: %{"EHOSCTL_CA_FILE" => ca})
    end

    test "with it naming another CA, the error says that CA did not sign the certificate", %{
      issuer: issuer,
      other: other
    } do
      env = %{"EHOSCTL_CA_FILE" => other}

      for result <- [
            SignIn.provider(issuer, env: env),
            HTTP.request(:get, issuer, "credential", nil, env: env)
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

      assert {:error, :invalid, message} =
               SignIn.provider(issuer, env: %{"EHOSCTL_CA_FILE" => missing})

      assert message == "cannot read EHOSCTL_CA_FILE=#{missing}: no such file or directory"
    end

    test "a file with one certificate that cannot be decoded is refused, though another does",
         %{issuer: issuer, ca: ca, tmp_dir: dir} do
      mixed = Path.join(dir, "mixed.pem")

      File.write!(
        mixed,
        File.read!(ca) <> "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"
      )

      assert SignIn.provider(issuer, env: %{"EHOSCTL_CA_FILE" => mixed}) ==
               {:error, :invalid,
                "EHOSCTL_CA_FILE=#{mixed} holds a certificate ehosctl cannot read"}
    end

    test "a path that is not a regular file, or a file larger than a CA bundle, is refused " <>
           "unread",
         %{issuer: issuer, tmp_dir: dir} do
      large = Path.join(dir, "large.pem")
      File.write!(large, :binary.copy("-", 1_048_577))

      assert SignIn.provider(issuer, env: %{"EHOSCTL_CA_FILE" => large}) ==
               {:error, :invalid,
                "EHOSCTL_CA_FILE=#{large} is larger than 1048576 bytes, more than a CA bundle is"}

      assert SignIn.provider(issuer, env: %{"EHOSCTL_CA_FILE" => dir}) ==
               {:error, :invalid, "EHOSCTL_CA_FILE=#{dir} is not a regular file"}
    end

    test "a path that would break the line it is said on is shown quoted", %{
      issuer: issuer,
      tmp_dir: dir
    } do
      missing = Path.join(dir, "ca\n.pem")

      assert {:error, :invalid, message} =
               SignIn.provider(issuer, env: %{"EHOSCTL_CA_FILE" => missing})

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
        env = %{"EHOSCTL_CA_FILE" => file}

        log =
          capture_log(fn ->
            for result <- [
                  SignIn.provider(issuer, env: env),
                  HTTP.request(:get, issuer, "credential", nil, env: env)
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
