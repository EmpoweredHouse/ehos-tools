defmodule Ehosctl.VerifyTest do
  # `ehosctl verify` (eh-os#355, ehos-tools#93): an application checked as its CI checks it, then
  # by EHOS when signed in.
  use Ehosctl.SignInCase

  alias Ehosctl.Verify

  @manifest ~s({"schema":"ehos.manifest/v2","application":"shop"})

  setup %{tmp_dir: tmp_dir, opts: opts} do
    app = Path.join(tmp_dir, "shop")
    File.mkdir_p!(app)
    File.write!(Path.join(app, "mix.exs"), "")
    File.write!(Path.join(app, "ehos.yaml"), "schema: ehos.yaml/v2\n")
    test = self()

    # Records each step and passes it; the manifest's gate writes the manifest, as Mix would.
    runner = fn cmd, args, env ->
      send(test, {:ran, cmd, args, env})

      if "eh_os_contract.manifest" in args,
        do: File.write!(Path.join(app, "ehos.manifest.json"), @manifest)

      0
    end

    %{app: app, opts: Keyword.merge(opts, dir: app, runner: runner, mise: "/bin/mise")}
  end

  defp ran do
    receive do
      {:ran, _cmd, args, env} -> [{args, env} | ran()]
    after
      0 -> []
    end
  end

  defp gates(ran), do: Enum.map(ran, fn {args, _env} -> Enum.drop_while(args, &(&1 != "mix")) end)

  describe "steps/3" do
    test "runs CI's gates in CI's order, under the application's own toolchain" do
      steps = Verify.steps("/bin/mise", "/src/shop")

      assert Enum.map(steps, & &1.args) == [
               ~w(-C /src/shop exec -- mix format --check-formatted),
               ~w(-C /src/shop exec -- mix compile --warnings-as-errors),
               ~w(-C /src/shop exec -- mix test),
               ~w(-C /src/shop exec -- mix eh_os_contract.check),
               ~w(-C /src/shop exec -- mix eh_os_contract.manifest --output ehos.manifest.json)
             ]

      for step <- steps do
        assert step.cmd == "/bin/mise"
        assert step.env == [{"MIX_ENV", "test"}, {"MISE_ACTIVATE_AGGRESSIVE", "1"}]
      end
    end

    test "leaves out the tests when asked" do
      refute Enum.any?(Verify.steps("/bin/mise", "/src/shop", test?: false), &("test" in &1.args))
    end
  end

  test "runs every gate, and says EHOS's check was left out without a sign-in", %{opts: opts} do
    {0, stdout, ""} = ehosctl(["verify"], opts)

    assert gates(ran()) == [
             ~w(mix format --check-formatted),
             ~w(mix compile --warnings-as-errors),
             ~w(mix test),
             ~w(mix eh_os_contract.check),
             ~w(mix eh_os_contract.manifest --output ehos.manifest.json)
           ]

    assert stdout =~ "==> mix format --check-formatted"
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
    assert stderr =~ "`mix compile --warnings-as-errors` exited with 3; nothing after it ran."
    refute stdout =~ "mix test"
  end

  test "refuses a directory that is not an application's, before running anything",
       %{app: app, opts: opts} do
    File.rm!(Path.join(app, "ehos.yaml"))

    {2, "", stderr} = ehosctl(["verify"], opts)
    assert stderr =~ "has no ehos.yaml"
    assert ran() == []
  end

  test "an installation named and unknown is an error, not a check left out", %{opts: opts} do
    {4, _stdout, stderr} = ehosctl(["verify", "--installation", "nowhere"], opts)
    assert stderr =~ "nowhere"
  end

  describe "signed in" do
    setup %{provider: provider, opts: opts} do
      login!(provider, opts)
      :ok
    end

    test "asks EHOS to check ehos.yaml and the manifest, each as it is",
         %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "POST", "/api/ehos-yaml/check", fn %{body: body} ->
        if String.starts_with?(body, "{"),
          do: {200, %{"valid" => true, "application" => "shop", "version" => "ehos.manifest/v2"}},
          else: {200, %{"valid" => true, "version" => "ehos.yaml/v1", "latest" => "ehos.yaml/v2"}}
      end)

      {0, stdout, ""} = ehosctl(["verify"], opts)
      assert stdout =~ "Every gate passed."

      assert stdout =~
               "EHOS accepts ehos.yaml, as ehos.yaml/v1; the newest schema is ehos.yaml/v2."

      assert stdout =~ "EHOS accepts ehos.manifest.json, the manifest of shop."

      assert [%{body: "schema: ehos.yaml/v2\n"}, %{body: @manifest}] =
               FakeProvider.requests(provider, "POST /api/ehos-yaml/check")
    end

    test "says what EHOS refuses, where, and exits 1", %{provider: provider, opts: opts} do
      FakeProvider.stub_api(provider, "POST", "/api/ehos-yaml/check", fn _ ->
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
      assert [_one] = FakeProvider.requests(provider, "POST /api/ehos-yaml/check")
    end

    test "a refusal of another kind is EHOS's, with its exit code", %{
      provider: provider,
      opts: opts
    } do
      FakeProvider.stub_api(provider, "POST", "/api/ehos-yaml/check", fn _ ->
        {413,
         %{"error" => "too_large", "message" => "The document is larger than 1048576 bytes."}}
      end)

      {2, _stdout, stderr} = ehosctl(["verify"], opts)
      assert stderr =~ "larger than 1048576 bytes"
    end

    test "refuses a manifest larger than EHOS takes, without sending it",
         %{provider: provider, app: app, opts: opts} do
      FakeProvider.stub_api(provider, "POST", "/api/ehos-yaml/check", fn _ ->
        {200, %{"valid" => true, "version" => "ehos.yaml/v2", "latest" => "ehos.yaml/v2"}}
      end)

      runner = fn _cmd, args, _env ->
        if "eh_os_contract.manifest" in args,
          do: File.write!(Path.join(app, "ehos.manifest.json"), String.duplicate("x", 1_048_577))

        0
      end

      {2, _stdout, stderr} = ehosctl(["verify"], Keyword.put(opts, :runner, runner))
      assert stderr =~ "ehos.manifest.json is larger than the 1048576 bytes EHOS takes."
      assert [_ehos_yaml_only] = FakeProvider.requests(provider, "POST /api/ehos-yaml/check")
    end
  end
end
