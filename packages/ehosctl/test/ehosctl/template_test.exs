defmodule Ehosctl.TemplateTest do
  use Ehosctl.Case, async: true

  alias Ehosctl.Template

  test "pins the commit ehos_app's release tag names, and that release's version" do
    {:ok, {:ehos_app, "== " <> version, opts}} = Template.install_dep()

    # Reads this repository's history and tags, which CI's checkout fetches whole for this.
    {tagged, status} = git(["rev-parse", "ehos_app-v#{version}^{commit}"])

    assert status == 0,
           "no tag ehos_app-v#{version} here (not a full git checkout of ehos-tools?): " <> tagged

    assert String.trim(tagged) == opts[:ref], "the pinned commit is not ehos_app-v#{version}'s"

    {mix_exs, 0} = git(["show", "#{opts[:ref]}:packages/ehos_app/mix.exs"])
    assert Regex.run(~r/@version "([^"]+)"/, mix_exs, capture: :all_but_first) == [version]

    # What `--version` says of the contract engine is what that commit's installer pins (T-11).
    {installer, 0} =
      git(["show", "#{opts[:ref]}:packages/ehos_app/lib/mix/tasks/ehos_app.install.ex"])

    assert Regex.run(~r/@eh_os_contract_release "v([^"]+)"/, installer, capture: :all_but_first) ==
             [Template.eh_os_contract_version()]
  end

  # The repository root's `.tool-versions` is what the template is developed under. It is
  # a copy of the pins above, so this keeps the two from drifting apart.
  test "the repository's .tool-versions matches the pinned toolchain" do
    assert File.read!(Path.expand("../../../../.tool-versions", __DIR__))
           |> String.split("\n", trim: true)
           |> Enum.reject(&String.starts_with?(&1, "#")) == [
             "erlang #{Template.erlang()}",
             "elixir #{Template.elixir()}"
           ]
  end

  # A generated project's CI runs `ehosctl verify` at the version the template's `check` job
  # pins, while its developers run the newest; a gate `verify` gains reaches CI only when the pin
  # moves (ehos-tools#332). An `ehosctl` release pins the `ehos_app` before it, so the newest the
  # template can pin is the newest released, and the pull request after an `ehosctl` tag moves
  # the pin (CONTRIBUTING.md, "Releasing `ehosctl`"). Only tags released before this commit
  # count: one on it is the release being built, whose binary does not exist yet, and one off its
  # history, a newer minor's, is not what a patch to an older minor pins.
  test "the template's CI runs the newest ehosctl this repository released" do
    pinned = pinned_ehosctl()

    # Reads this repository's tags, which CI's checkout fetches whole for this.
    {tags, 0} = git(["tag", "--list", "v*", "--merged", "HEAD", "--no-contains", "HEAD"])

    released =
      for "v" <> tag <- String.split(tags),
          {:ok, %Version{pre: []} = version} <- [Version.parse(tag)],
          do: version

    assert released != [], "no v* tag here (not a full git checkout of ehos-tools?)"
    newest = released |> Enum.max(Version) |> to_string()

    assert pinned == newest,
           "ehos_app's ci.yml.eex pins ehosctl #{pinned}, and #{newest} is released: set its " <>
             "PINNED_EHOSCTL_VERSION, and PINNED_EHOSCTL_SHA256 to the SHA-256 alone from the " <>
             "ehosctl_linux_x64 line of the release's SHA256SUMS, and, when an ehos_app release " <>
             "wrote the workflow it replaces, add that workflow's hash to @earlier_ci_workflows " <>
             "and its fixture"
  end

  # The template's CI tells EHOS refusing a job's token from any other failure by how the
  # message the pinned `ehosctl` prints for it begins. That message is `refused/2`'s in
  # `Ehosctl.GitHubActions`, built here from its source at the pinned release's tag and at this
  # commit: a change to either side fails in its own pull request, and a release that rewords it
  # fails before the pin reaches it.
  test "the template's CI tells the pinned ehosctl's refusal of a job's token, and this one's" do
    %{jq_string: jq_string} = register_check()

    # A jq string, whose `\\` is one backslash in the regex; Oniguruma and PCRE read it alike.
    refusal = jq_string |> String.replace("\\\\", "\\") |> Regex.compile!()

    for {ehosctl, source} <- ehosctl_sources("lib/ehosctl/github_actions.ex") do
      assert Regex.match?(refusal, refused(source, "https://ehos.example.com")),
             "ehos_app's ci.yml.eex matches #{inspect(refusal.source)} against the refusal of a " <>
               "job's token, and ehosctl #{ehosctl} words it otherwise"
    end
  end

  # The wording alone does not tell the refusal: the step reads it only under the exit code it
  # expects, and only where `--json` puts an error's message. Both are `Ehosctl.Output`'s,
  # `@codes` and `error/3`, and the refusal's kind is the exchange's, read here as the message is.
  test "the template's CI reads the pinned ehosctl's refusal under its exit code and at its path, and this one's" do
    %{code: code, path: path} = register_check()

    pairs =
      Enum.zip(
        ehosctl_sources("lib/ehosctl/github_actions.ex"),
        ehosctl_sources("lib/ehosctl/output.ex")
      )

    for {{ehosctl, actions}, {same, output}} <- pairs do
      assert same == ehosctl

      assert refusal_kind(actions) == :refused,
             "ehosctl #{ehosctl} answers EHOS refusing a job's token as no :refused error"

      assert Keyword.get(attribute(output, :codes), :refused) == code,
             "ehos_app's ci.yml.eex reads the refusal of a job's token under exit code #{code}, " <>
               "and ehosctl #{ehosctl} exits with another for :refused"

      # The step reads the JSON from `ehosctl`'s stderr, as `2> "$RUNNER_TEMP/register.err"`.
      assert error_devices(output) == [:stderr],
             "ehos_app's ci.yml.eex reads an error from stderr, and ehosctl #{ehosctl} prints it " <>
               "elsewhere"

      assert get_in(error_json(output, "the message"), path) == "the message",
             "ehos_app's ci.yml.eex reads an error's message at .#{Enum.join(path, ".")}, and " <>
               "ehosctl #{ehosctl}'s --json puts it elsewhere"
    end
  end

  # The preview step tells a refusal at the count by its code alone: under the exit code of the
  # codes' kind, in the JSON on stderr, at the path where `Ehosctl.Output.error/4` prints the code
  # that `Ehosctl.Refusal` kept. Each code is one `Refusal` gives the kind `:failed`.
  test "the template's CI reads the pinned ehosctl's code at the count under its exit code and at its path, and this one's" do
    %{codes: codes, code: code, path: path} = preview_check()

    pairs =
      Enum.zip(
        ehosctl_sources("lib/ehosctl/refusal.ex"),
        ehosctl_sources("lib/ehosctl/output.ex")
      )

    for {{ehosctl, refusal}, {same, output}} <- pairs do
      assert same == ehosctl

      assert codes -- attribute(refusal, :failed) == [],
             "ehos_app's ci.yml.eex reads #{Enum.join(codes, " and ")} under the exit code of " <>
               ":failed, and ehosctl #{ehosctl} gives one of them another kind"

      assert Keyword.get(attribute(output, :codes), :failed) == code,
             "ehos_app's ci.yml.eex reads a refusal at the count under exit code #{code}, and " <>
               "ehosctl #{ehosctl} exits with another for :failed"

      assert error_devices(output) == [:stderr],
             "ehos_app's ci.yml.eex reads an error from stderr, and ehosctl #{ehosctl} prints it " <>
               "elsewhere"

      assert get_in(error_json(output, "the message", %{"code" => "the code"}), path) ==
               "the code",
             "ehos_app's ci.yml.eex reads a refusal's code at .#{Enum.join(path, ".")}, and " <>
               "ehosctl #{ehosctl}'s --json puts it elsewhere"
    end
  end

  # 0.29.0, the release after 0.28.0, is the first whose `verify` audits the dependencies
  # (ehos-tools#507), so a workflow that pins it needs no step of its own, which until then
  # stands in for it.
  test "the template's CI audits the dependencies once" do
    audits_itself? = workflow() =~ ~r/^\s+(- )?run: mix hex\.audit\b/m
    assert audits_itself? == Version.match?(pinned_ehosctl(), "< 0.29.0")
  end

  # The pins live in `Ehosctl.Template` alone (AGENTS.md); `docs/commands/init.md` lists them for
  # a reader, and moved by hand with every release it could fall behind with nothing failing.
  # The page says each in its own words, so the rows are built here, and a pin added to
  # `pins/0` without a row fails as one left behind does.
  test "the reference page of init lists the pins this release has" do
    {:ok, {:ehos_app, _, opts}} = Template.install_dep()
    ref = opts[:ref]
    version = Template.template_version()

    t11 =
      "https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/" <>
        "0011-a-generated-project-pins-eh-os-contract-s-release-by-the-commit-its-tag-names.md"

    page = File.read!(Path.expand("../../docs/commands/init.md", __DIR__))

    table =
      Regex.run(
        ~r/^## What it pins\n(?:(?!## ).*\n)*?\| Pin \| Value \|\n\| --- \| --- \|\n((?:\|.*(?:\n|\z))+)/m,
        page,
        capture: :all_but_first
      )

    assert table, "docs/commands/init.md has no table under \"## What it pins\""
    rows = table |> hd() |> String.split("\n", trim: true)

    labels =
      for row <- rows do
        Regex.run(~r/^\| `?([^|`]+?)`? \|/, row, capture: :all_but_first) ||
          flunk("cannot read the pin's name in docs/commands/init.md's row #{row}")
      end

    assert Enum.sort(labels) == Enum.sort(for {label, _} <- Template.pins(), do: [label])

    assert rows == [
             "| Erlang | #{Template.erlang()} |",
             "| Elixir | #{Template.elixir()} |",
             "| `phx_new` | #{Template.phx_new()} |",
             "| `igniter_new` | #{Template.igniter_new()} |",
             "| `ehos_app` | [`packages/ehos_app`](https://github.com/EmpoweredHouse/ehos-tools/" <>
               "tree/#{ref}/packages/ehos_app) of ehos-tools at `#{String.slice(ref, 0, 7)}`, " <>
               "the commit the tag `ehos_app-v#{version}` names |",
             "| `eh_os_contract` | #{Template.eh_os_contract_version()}, which `ehos_app` " <>
               "#{version} pins ([T-11](#{t11})) |"
           ]
  end

  describe "install_dep/0" do
    test "installs the pinned ehos_app by default, at a commit of ehos-tools, which cannot move" do
      {:ok,
       {:ehos_app, "== " <> version,
        [github: "EmpoweredHouse/ehos-tools", sparse: "packages/ehos_app", ref: ref]}} =
        Template.install_dep()

      # The commit is the pin itself, which the first test holds to its tag.
      assert ref =~ ~r/\A[0-9a-f]{40}\z/
      # The version the pinned commit's `mix.exs` has: a commit of another version fails
      # `deps.get` instead of running as the installer.
      assert version == Template.template_version()
      assert match?({:ok, %Version{}}, Version.parse(version))
    end

    test "EHOSCTL_TEMPLATE_SOURCE=path: installs a local checkout" do
      stub_env(%{"EHOSCTL_TEMPLATE_SOURCE" => "path:/abs/ehos_app"})
      assert Template.install_dep() == {:ok, {:ehos_app, path: "/abs/ehos_app", override: true}}
    end

    test "EHOSCTL_TEMPLATE_SOURCE=ref: installs another ref of ehos-tools" do
      stub_env(%{"EHOSCTL_TEMPLATE_SOURCE" => "ref:1a2b3c"})

      assert Template.install_dep() ==
               {:ok,
                {:ehos_app,
                 [github: "EmpoweredHouse/ehos-tools", sparse: "packages/ehos_app", ref: "1a2b3c"]}}
    end

    test "an empty EHOSCTL_TEMPLATE_SOURCE is taken as unset" do
      stub_env(%{"EHOSCTL_TEMPLATE_SOURCE" => ""})
      default = Template.install_dep()
      stub_env(%{})
      assert default == Template.install_dep()
    end

    test "EHOSCTL_TEMPLATE_SOURCE refuses a relative path, or anything else" do
      for source <- ["path:rel/ehos_app", "github:EmpoweredHouse/ehos_app@v0.2.0", "ref:"] do
        stub_env(%{"EHOSCTL_TEMPLATE_SOURCE" => source})

        assert Template.install_dep() ==
                 {:error,
                  "EHOSCTL_TEMPLATE_SOURCE is #{inspect(source)}, and ehosctl does not " <>
                    "accept it. Give path:PATH, with the absolute path of packages/ehos_app, " <>
                    "or ref:REF, with a git ref of EmpoweredHouse/ehos-tools."}
      end
    end
  end

  describe "install_expression/1" do
    test "passes the pinned version's requirement to Igniter with the commit" do
      {:ok, {:ehos_app, _requirement, opts} = dep} = Template.install_dep()

      assert Template.install_expression(dep) ==
               "{:ok, _} = Application.ensure_all_started(:rewrite); " <>
                 ~s|Igniter.Util.Install.install([{:ehos_app, "== #{Template.template_version()}", | <>
                 ~s|[github: "EmpoweredHouse/ehos-tools", sparse: "packages/ehos_app", | <>
                 ~s|ref: "#{opts[:ref]}"]}], ["--example", "--yes"])|
    end

    test "installs through Igniter, which composes the installers ehos_app declares" do
      dep = {:ehos_app, path: "/abs/ehos_app", override: true}

      assert Template.install_expression(dep) ==
               "{:ok, _} = Application.ensure_all_started(:rewrite); " <>
                 ~s|Igniter.Util.Install.install([{:ehos_app, [path: "/abs/ehos_app", | <>
                 ~s|override: true]}], ["--example", "--yes"])|
    end
  end

  defp git(args), do: System.cmd("git", args, stderr_to_stdout: true)

  defp workflow,
    do:
      File.read!(
        Path.expand("../../../ehos_app/priv/templates/ehos_app.install/ci.yml.eex", __DIR__)
      )

  defp pinned_ehosctl do
    [_, pinned] = Regex.run(~r/^  PINNED_EHOSCTL_VERSION: ["']?([^"'\s#]+)/m, workflow())
    pinned
  end

  # What the register step of the template's CI reads of a failed `ehosctl builds register`: the
  # exit code it compares, the path of the message in the JSON on stderr, and the jq string it
  # tests that message against, in the file the command's stderr went to.
  defp register_check do
    [_, stderr] =
      Regex.run(~r/ehosctl builds register .* --json > \S+ 2> (\S+)/, workflow()) ||
        flunk(
          "ehos_app's ci.yml.eex runs no `ehosctl builds register --json` with its stderr in a file"
        )

    [_, code, path, jq_string, read] =
      Regex.run(
        ~r/\[ "\$code" = (\d+) \] && \[ "\$GITHUB_EVENT_NAME" = push \] &&\s+jq -e '((?:\.\w+)+) \| test\("((?:[^"\\]|\\.)*)"\)' (\S+)/,
        workflow()
      ) || flunk("ehos_app's ci.yml.eex has no check of the register step's refusal")

    assert read == stderr,
           "ehos_app's ci.yml.eex tests the refusal in #{read}, and `ehosctl builds register` " <>
             "writes its stderr to #{stderr}"

    %{
      code: String.to_integer(code),
      path: String.split(path, ".", trim: true),
      jq_string: jq_string
    }
  end

  # What the preview step of the template's CI reads of a failed `ehosctl env create`: the exit
  # code it compares, the path of the code in the JSON on stderr, and the codes it takes for a
  # refusal at the count, in the file the command's stderr went to.
  defp preview_check do
    [_, stderr] =
      Regex.run(~r/ehosctl env create .* --json 2> (\S+)/, workflow()) ||
        flunk(
          "ehos_app's ci.yml.eex runs no `ehosctl env create --json` with its stderr in a file"
        )

    [_, code, path, any, read] =
      Regex.run(
        ~r/\[ "\$code" = (\d+) \] &&\s+jq -Rne '\[inputs \| fromjson\? \| ((?:\.\w+\??)+) \| strings\] \| any\(([^)]*)\)' (\S+)/,
        workflow()
      ) || flunk("ehos_app's ci.yml.eex has no check of the preview step's refusal at the count")

    assert read == stderr,
           "ehos_app's ci.yml.eex tests the refusal in #{read}, and `ehosctl env create` " <>
             "writes its stderr to #{stderr}"

    %{
      code: String.to_integer(code),
      path: path |> String.replace("?", "") |> String.split(".", trim: true),
      codes: for([_, code] <- Regex.scan(~r/"(\w+)"/, any), do: code)
    }
  end

  # The source of `path`, under packages/ehosctl, at the pinned release's tag and at this commit.
  defp ehosctl_sources(path) do
    pinned = pinned_ehosctl()

    # Reads this repository's tags, which CI's checkout fetches whole for this.
    {source, status} = git(["show", "v#{pinned}:packages/ehosctl/#{path}"])
    assert status == 0, "no packages/ehosctl/#{path} at the tag v#{pinned}: " <> source

    [{pinned, source}, {"at this commit", File.read!(path)}]
  end

  # The kind of error the exchange answers EHOS's `invalid_grant` with, in the clause of
  # `exchange_answered/3` whose head names it.
  defp refusal_kind(source) do
    source
    |> Code.string_to_quoted!()
    |> found(fn
      {:defp, _, [{:exchange_answered, _, [answer, _, _]}, [do: body]]} ->
        if found(answer, &(&1 == "invalid_grant" || nil)),
          do: found(body, &error_kind/1)

      _ ->
        nil
    end) || flunk("no {:error, kind, _} for invalid_grant in Ehosctl.GitHubActions")
  end

  defp error_kind({:{}, _, [:error, kind, _]}), do: kind
  defp error_kind(_), do: nil

  # The literal value of a module attribute in `source`.
  defp attribute(source, name) do
    value =
      source
      |> Code.string_to_quoted!()
      |> found(fn
        {:@, _, [{^name, _, [value]}]} -> value
        _ -> nil
      end) || flunk("no @#{name} in the source")

    evaluated(value, [], "@#{name}")
  end

  # Every device `error/3` prints to through an `IO.puts`, `IO.write` or `IO.binwrite` written in
  # any of its clauses, guarded or not, once each: stdout for a print that names none, and
  # `:standard_error` as the `:stderr` it is. From ehosctl 0.36.0 it is `error/4`, whose last
  # argument has a default.
  defp error_devices(source) do
    devices =
      source
      |> Code.string_to_quoted!()
      |> all(fn
        {:def, _, [{:error, _, [_, _, _ | _]}, body]} ->
          body |> unpiped() |> all(&print_device/1)

        {:def, _, [{:when, _, [{:error, _, [_, _, _ | _]}, _]}, body]} ->
          body |> unpiped() |> all(&print_device/1)

        _ ->
          []
      end)

    assert devices != [], "no IO print in Ehosctl.Output.error/3"
    Enum.uniq(devices)
  end

  # A pipe as the call it is, the piped value its first argument: `:stderr |> IO.puts(line)` is
  # `IO.puts(:stderr, line)`.
  defp unpiped(quoted) do
    Macro.prewalk(quoted, fn
      {:|>, _, [piped, {call, meta, args}]} when is_list(args) -> {call, meta, [piped | args]}
      node -> node
    end)
  end

  defp print_device({{:., _, [{:__aliases__, _, [:IO]}, print]}, _, args})
       when print in [:puts, :write, :binwrite],
       do: [device(args)]

  defp print_device(_), do: []

  defp device(args) when length(args) < 2, do: :stdio
  defp device([:standard_error, _]), do: :stderr
  defp device([device, _]), do: device

  # The JSON `error/3` prints for a message, and from ehosctl 0.36.0 `error/4` for a message and
  # the fields of a refusal, as jq reads it.
  defp error_json(source, message, refusal \\ %{}) do
    map =
      source
      |> Code.string_to_quoted!()
      |> found(fn
        {:def, _, [{:error, _, [_, _, _ | _]}, [do: body]]} ->
          found(body, fn
            {:json, _, [{:%{}, _, _} = map]} -> map
            _ -> nil
          end)

        _ ->
          nil
      end) || flunk("no json(%{...}) in Ehosctl.Output.error/3")

    map
    |> evaluated([kind: :refused, message: message, refusal: refusal], "error/3's JSON")
    |> JSON.encode!()
    |> JSON.decode!()
  end

  # Outside its module an expression has no alias, attribute or private function, and a renamed
  # variable is not bound: one that needs them cannot be read here, which says nothing of what it
  # gives.
  defp evaluated(quoted, binding, what) do
    quoted |> Code.eval_quoted(binding) |> elem(0)
  rescue
    error ->
      flunk(
        "#{what} cannot be read outside its module, so this test cannot check it: " <>
          Exception.message(error)
      )
  end

  # What `fun` returns for every node of a quoted expression, a list each, joined.
  defp all(ast, fun) do
    {_, values} = Macro.prewalk(ast, [], fn node, values -> {node, values ++ fun.(node)} end)
    values
  end

  # What `fun` returns for the first node of a quoted expression it returns a value for.
  defp found(ast, fun) do
    {_, value} =
      Macro.prewalk(ast, nil, fn
        node, nil -> {node, fun.(node)}
        node, value -> {node, value}
      end)

    value
  end

  # The message `refused(issuer, application)` builds in `source`, for a job that names no
  # application: the opening sentence the workflow matches does not depend on it.
  defp refused(source, issuer) do
    {_, body} =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk(nil, fn
        {:defp, _, [{:refused, _, [_, _]}, [do: body]]} = node, nil -> {node, body}
        node, found -> {node, found}
      end)

    assert body, "no refused/2 in Ehosctl.GitHubActions"

    evaluated(body, [issuer: issuer, application: nil], "refused/2")
  end
end
