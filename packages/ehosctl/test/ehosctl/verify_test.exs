defmodule Ehosctl.VerifyTest do
  # `ehosctl verify` (eh-os#355, ehos-tools#93): an application checked as its CI checks it, then
  # by EHOS when an installation is chosen.
  use Ehosctl.SignInCase

  alias Ehosctl.Verify

  @manifest ~s({"schema":"ehos.manifest/v2","application":"shop"})

  setup %{tmp_dir: tmp_dir, opts: opts} do
    app = Path.join(tmp_dir, "shop")
    File.mkdir_p!(Path.join(app, "_build"))
    File.write!(Path.join(app, "mix.exs"), "")
    File.write!(Path.join(app, "ehos.yaml"), "schema: ehos.yaml/v2\n")
    File.write!(Path.join(app, ".tool-versions"), "erlang 28.5.0.7\nelixir 1.20.4-otp-28\n")
    test = self()

    # Records each step and passes it; the manifest's gate writes the manifest, as Mix would.
    runner = fn cmd, args, env ->
      send(test, {:ran, cmd, args, env})
      if "eh_os_contract.manifest" in args, do: write_manifest(app, @manifest)
      0
    end

    %{app: app, opts: Keyword.merge(opts, dir: app, runner: runner, mise: "/bin/mise")}
  end

  defp write_manifest(app, contents),
    do: File.write!(Path.join(app, "_build/ehos.manifest.json"), contents)

  defp ran do
    receive do
      {:ran, _cmd, args, env} -> [{args, env} | ran()]
    after
      0 -> []
    end
  end

  defp gates(ran), do: Enum.map(ran, fn {args, _env} -> Enum.drop_while(args, &(&1 != "mix")) end)

  @gates [
    ~w(mix deps.get --only test --check-locked),
    ~w(mix format --check-formatted),
    ~w(mix compile --warnings-as-errors),
    ~w(mix test),
    ~w(mix eh_os_contract.check),
    ~w(mix eh_os_contract.manifest --output _build/ehos.manifest.json)
  ]

  describe "steps/3" do
    test "runs CI's gates in CI's order, under the application's own toolchain" do
      steps = Verify.steps("/bin/mise", "/src/shop")

      assert Enum.map(steps, & &1.args) ==
               Enum.map(@gates, &(~w(-C /src/shop exec --) ++ &1))

      for step <- steps do
        assert step.cmd == "/bin/mise"
        assert step.env == [{"MIX_ENV", "test"}, {"MISE_ACTIVATE_AGGRESSIVE", "1"}]
      end
    end

    test "leaves out the tests when asked" do
      steps = Verify.steps("/bin/mise", "/src/shop", test?: false)

      refute ~w(mix test) in Enum.map(steps, fn step ->
               Enum.drop_while(step.args, &(&1 != "mix"))
             end)
    end
  end

  test "runs every gate, and says EHOS's check was left out with no installation chosen",
       %{opts: opts} do
    {0, stdout, ""} = ehosctl(["verify"], opts)

    assert gates(ran()) == @gates
    assert stdout =~ "==> mix format --check-formatted"
    assert stdout =~ "Every gate passed."
    assert stdout =~ "EHOS's check of ehos.yaml and the manifest was left out"
    assert stdout =~ "ehosctl login"
  end

  test "--no-test leaves out the tests", %{opts: opts} do
    {0, _stdout, ""} = ehosctl(["verify", "--no-test"], opts)
    refute ~w(mix test) in gates(ran())
  end

  test "stops at the first gate that fails, with exit 1", %{opts: opts} do
    runner = fn _cmd, args, _env -> if "compile" in args, do: 3, else: 0 end

    {1, stdout, stderr} = ehosctl(["verify"], Keyword.put(opts, :runner, runner))
    assert stderr =~ "`mix compile --warnings-as-errors` exited with 3"
    assert stderr =~ "nothing after it ran."
    refute stdout =~ "mix test"
  end

  test "refuses a directory that is not an application's, before running anything",
       %{app: app, opts: opts} do
    File.rm!(Path.join(app, "ehos.yaml"))
    File.rm!(Path.join(app, ".tool-versions"))

    {2, "", stderr} = ehosctl(["verify"], opts)
    assert stderr =~ "has no ehos.yaml and no .tool-versions"
    assert ran() == []
  end

  test "a manifest the gate did not write fails, with no installation chosen", %{opts: opts} do
    {1, _stdout, stderr} = ehosctl(["verify"], Keyword.put(opts, :runner, fn _, _, _ -> 0 end))
    assert stderr =~ "_build/ehos.manifest.json cannot be read"
  end

  test "an installation named and unknown is an error before any gate, not a check left out",
       %{opts: opts} do
    {4, _stdout, stderr} = ehosctl(["verify", "--installation", "nowhere"], opts)
    assert stderr =~ "nowhere"

    env = %{"EHOSCTL_INSTALLATION" => "elsewhere"}
    {4, _stdout, stderr} = ehosctl(["verify"], Keyword.put(opts, :env, env))
    assert stderr =~ "elsewhere"
    assert ran() == []
  end

  describe "signed in" do
    setup %{provider: provider, opts: opts} do
      login!(provider, opts)
      :ok
    end

    defp accept_both(provider) do
      FakeProvider.stub_api(provider, "POST", "/api/v1/ehos-yaml/check", fn %{body: body} ->
        if String.starts_with?(body, "{"),
          do: {200, %{"valid" => true, "application" => "shop", "version" => "ehos.manifest/v2"}},
          else: {200, %{"valid" => true, "version" => "ehos.yaml/v1", "latest" => "ehos.yaml/v2"}}
      end)
    end

    test "asks EHOS to check ehos.yaml and the manifest, each as it is",
         %{provider: provider, opts: opts} do
      accept_both(provider)

      {0, stdout, ""} = ehosctl(["verify"], opts)
      assert stdout =~ "Every gate passed."
      assert stdout =~ "EHOS at #{provider.issuer}:"
      assert stdout =~ "accepts ehos.yaml, as ehos.yaml/v1; the newest schema is ehos.yaml/v2."
      assert stdout =~ "accepts the manifest of shop, as ehos.manifest/v2."

      assert [%{body: "schema: ehos.yaml/v2\n"}, %{body: @manifest}] =
               FakeProvider.requests(provider, "POST /api/v1/ehos-yaml/check")
    end

    test "says what EHOS refuses, where, and exits 1", %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "POST", "/api/v1/ehos-yaml/check", fn _ ->
        {422,
         %{
           "valid" => false,
           "errors" => [
             %{"path" => "needs.database", "line" => 3, "message" => "is not one of …"},
             %{"path" => "", "line" => nil, "message" => "and 4 more"},
             %{"path" => "schema", "line" => nil, "message" => "say \e[2J"}
           ]
         }}
      end)

      {1, _stdout, stderr} = ehosctl(["verify"], opts)
      assert stderr =~ "EHOS refuses ehos.yaml:"
      assert stderr =~ "needs.database (line 3): is not one of …"
      assert stderr =~ "  - and 4 more"
      refute stderr =~ "\e[2J"
      assert [_one] = FakeProvider.requests(provider, "POST /api/v1/ehos-yaml/check")
    end

    test "a refusal of another kind is EHOS's, with its exit code",
         %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "POST", "/api/v1/ehos-yaml/check", fn _ ->
        {413,
         %{"error" => "too_large", "message" => "The document is larger than 1048576 bytes."}}
      end)

      {2, _stdout, stderr} = ehosctl(["verify"], opts)
      assert stderr =~ "larger than 1048576 bytes"
    end

    test "a credential EHOS refuses is an error, not a check left out",
         %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "POST", "/api/v1/ehos-yaml/check", fn _ ->
        {401, %{"error" => "disabled", "message" => "This person is disabled."}}
      end)

      {4, _stdout, stderr} = ehosctl(["verify"], opts)
      assert stderr =~ "disabled"
    end

    test "an answer of the other kind is not taken for acceptance",
         %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "POST", "/api/v1/ehos-yaml/check", fn _ ->
        {200, %{"valid" => true, "application" => "shop", "version" => "ehos.manifest/v2"}}
      end)

      {1, _stdout, stderr} = ehosctl(["verify"], opts)
      assert stderr =~ "did not read ehos.yaml as an ehos.yaml"
    end

    test "refuses a manifest larger than EHOS takes, without sending anything",
         %{provider: provider, app: app, opts: opts} do
      accept_both(provider)

      runner = fn _cmd, args, _env ->
        if "eh_os_contract.manifest" in args,
          do: write_manifest(app, String.duplicate("x", 1_048_577))

        0
      end

      {1, _stdout, stderr} = ehosctl(["verify"], Keyword.put(opts, :runner, runner))
      assert stderr =~ "_build/ehos.manifest.json is larger than the 1048576 bytes EHOS takes."
      assert FakeProvider.requests(provider, "POST /api/v1/ehos-yaml/check") == []
    end

    test "sends no file a link points to, and says so before any gate",
         %{provider: provider, app: app, opts: opts} do
      accept_both(provider)
      secret = Path.join(Path.dirname(app), "secret")
      File.write!(secret, "not for EHOS")
      File.rm!(Path.join(app, "ehos.yaml"))
      File.ln_s!(secret, Path.join(app, "ehos.yaml"))

      {2, _stdout, stderr} = ehosctl(["verify"], opts)
      assert stderr =~ "has no ehos.yaml as a regular file"
      assert ran() == []
      assert FakeProvider.requests(provider, "POST /api/v1/ehos-yaml/check") == []
    end

    test "refuses a link where the manifest goes, before the gate writes through it",
         %{app: app, opts: opts} do
      target = Path.join(Path.dirname(app), "rc")
      File.write!(target, "kept")
      File.ln_s!(target, Path.join(app, "_build/ehos.manifest.json"))

      {2, _stdout, stderr} = ehosctl(["verify"], opts)
      assert stderr =~ "_build/ehos.manifest.json is not a regular file (symlink)"
      assert ran() == []
      assert File.read!(target) == "kept"
    end

    test "sends an empty ehos.yaml as it is", %{provider: provider, app: app, opts: opts} do
      accept_both(provider)
      File.write!(Path.join(app, "ehos.yaml"), "")

      {0, _stdout, ""} = ehosctl(["verify"], opts)

      assert [%{body: ""}, _manifest] =
               FakeProvider.requests(provider, "POST /api/v1/ehos-yaml/check")
    end
  end
end
