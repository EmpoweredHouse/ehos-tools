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
    assert [_, ^version] = Regex.run(~r/@version "([^"]+)"/, mix_exs)

    # What `--help` says of the contract engine is what that commit's installer pins (T-11).
    {installer, 0} =
      git(["show", "#{opts[:ref]}:packages/ehos_app/lib/mix/tasks/ehos_app.install.ex"])

    assert [_, pinned] = Regex.run(~r/@eh_os_contract_release "v([^"]+)"/, installer)
    assert pinned == Template.eh_os_contract_version()
  end

  defp git(args), do: System.cmd("git", args, stderr_to_stdout: true)

  test "installs the pinned ehos_app by default, at a commit of ehos-tools, which cannot move" do
    assert {:ok,
            {:ehos_app, "== " <> version,
             [
               github: "EmpoweredHouse/ehos-tools",
               sparse: "packages/ehos_app",
               ref: ref
             ]}} =
             Template.install_dep()

    assert ref =~ ~r/\A[0-9a-f]{40}\z/
    # The version the pinned commit's `mix.exs` has: a commit of another version fails
    # `deps.get` instead of running as the installer.
    assert {:ok, _} = Version.parse(version)
  end

  test "EHOSCTL_TEMPLATE_SOURCE=path: installs a local checkout" do
    stub_env(%{"EHOSCTL_TEMPLATE_SOURCE" => "path:/abs/ehos_app"})
    assert Template.install_dep() == {:ok, {:ehos_app, path: "/abs/ehos_app", override: true}}
  end

  test "EHOSCTL_TEMPLATE_SOURCE=ref: installs another ref of ehos-tools" do
    stub_env(%{"EHOSCTL_TEMPLATE_SOURCE" => "ref:1a2b3c"})
    assert {:ok, {:ehos_app, opts}} = Template.install_dep()
    assert opts[:ref] == "1a2b3c"
    refute opts[:tag]
  end

  test "EHOSCTL_TEMPLATE_SOURCE refuses a relative path, or anything else" do
    for source <- ["path:rel/ehos_app", "github:EmpoweredHouse/ehos_app@v0.2.0", "ref:"] do
      stub_env(%{"EHOSCTL_TEMPLATE_SOURCE" => source})
      assert {:error, message} = Template.install_dep()
      assert message =~ "path:<absolute path"
    end
  end

  test "an empty EHOSCTL_TEMPLATE_SOURCE is taken as unset" do
    stub_env(%{"EHOSCTL_TEMPLATE_SOURCE" => ""})
    default = Template.install_dep()
    stub_env(%{})
    assert default == Template.install_dep()
  end

  test "passes the pinned version's requirement to Igniter with the commit" do
    stub_env(%{})
    {:ok, dep} = Template.install_dep()
    code = Template.install_expression(dep)

    assert {:ok, _} = Code.string_to_quoted(code)
    assert code =~ ~r/\{:ehos_app, "== \d+\.\d+\.\d+", \[github: /
  end

  test "installs through Igniter, which composes the installers ehos_app declares" do
    dep = {:ehos_app, path: "/abs/ehos_app", override: true}
    code = Template.install_expression(dep)

    assert {:ok, _} = Code.string_to_quoted(code)

    assert code =~
             ~s|Igniter.Util.Install.install([{:ehos_app, [path: "/abs/ehos_app", override: true]}], ["--example", "--yes"])|

    assert code =~ "Application.ensure_all_started(:rewrite)"
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
           "ehos_app's ci.yml.eex pins ehosctl #{pinned}, and #{newest} is released: move the " <>
             "pin, the name of the step that checks the binary and its SHA-256 (the release's " <>
             "SHA256SUMS, ehosctl_linux_x64), and, when an ehos_app release wrote the workflow " <>
             "it replaces, add that workflow's hash to @earlier_ci_workflows and its fixture"

    assert workflow() =~ "- name: Check ehosctl is #{pinned}'s binary"
  end

  # 0.29.0, the release after 0.28.0, is the first whose `verify` audits the dependencies
  # (ehos-tools#507), so a workflow that pins it needs no step of its own, which until then
  # stands in for it.
  test "the template's CI audits the dependencies once" do
    audits_itself? = workflow() =~ ~r/^\s+(- )?run: mix hex\.audit\b/m
    assert audits_itself? == Version.match?(pinned_ehosctl(), "< 0.29.0")
  end

  defp workflow,
    do:
      File.read!(
        Path.expand("../../../ehos_app/priv/templates/ehos_app.install/ci.yml.eex", __DIR__)
      )

  defp pinned_ehosctl do
    [_, pinned] = Regex.run(~r/mise use -g github:EmpoweredHouse\/ehos-tools@(\S+)/, workflow())
    pinned
  end
end
