defmodule Ehosctl.ServiceWorkflowTest do
  # T-27: a utility service's pipeline is `.github/workflows/ehos-service.yml`, released by
  # ehosctl's tag, which installs the ehosctl of that tag, checked against that release's
  # SHA256SUMS; the caller `ehosctl init --service` writes names it by commit and grants what its
  # jobs ask for (ehos-tools#917). YAML is read with YamlElixir, which ehos_platform brings in
  # every environment.
  use ExUnit.Case, async: true

  alias Ehosctl.InitService

  @root Path.expand("../../../..", __DIR__)
  @path ".github/workflows/ehos-service.yml"

  setup_all do
    text = File.read!(Path.join(@root, @path))
    {:ok, ref} = InitService.ref("1.2.3", String.duplicate("a", 40))
    caller = YamlElixir.read_from_string!(InitService.workflow("invoice-pdf", ref))
    %{text: text, workflow: YamlElixir.read_from_string!(text), caller: caller}
  end

  test "installs the ehosctl of the release that mix.exs names, without -dev",
       %{workflow: workflow} do
    version = String.replace_suffix(Mix.Project.config()[:version], "-dev", "")
    assert workflow["env"] == %{"PINNED_EHOSCTL_VERSION" => version}
  end

  test "runs the binary of each install only if the release's SHA256SUMS names it",
       %{workflow: workflow} do
    installs =
      for {job, %{"steps" => steps}} <- workflow["jobs"],
          %{"run" => run} <- steps,
          run =~ "gh release download",
          do: {job, String.split(run, "\n", trim: true)}

    assert Enum.map(installs, &elem(&1, 0)) |> Enum.sort() ==
             ~w(check preview preview-remove publish)

    for {_job, lines} <- installs do
      assert lines == [
               ~S(gh release download "v$PINNED_EHOSCTL_VERSION" --repo EmpoweredHouse/ehos-tools --pattern ehosctl_linux_x64 --pattern SHA256SUMS --dir "$RUNNER_TEMP/ehosctl"),
               ~S<(cd "$RUNNER_TEMP/ehosctl" && grep -E '^[0-9a-f]{64}  ehosctl_linux_x64$' SHA256SUMS | sha256sum --check --strict -)>,
               ~S(install -m 0755 "$RUNNER_TEMP/ehosctl/ehosctl_linux_x64" /usr/local/bin/ehosctl),
               "ehosctl --version"
             ]
    end
  end

  # D-110: a job may ask GitHub for a token EHOS accepts, so it runs no action a tag could move.
  test "pins every action it runs by a commit, its tag beside it", %{text: text} do
    uses = Regex.scan(~r/^\s*(?:- )?uses: (.+)$/m, text, capture: :all_but_first)

    assert uses != []

    for [action] <- uses,
        do: assert(action =~ ~r/\A[\w.-]+\/[\w.-]+@[0-9a-f]{40} # v\d/, action)
  end

  # ehos-tools is public: a job reads its release with its own token, so the caller passes no
  # secret, and a key of the caller's never reaches this workflow (ehos-tools#1169).
  test "takes no secrets, and the caller passes none", %{workflow: workflow, caller: caller} do
    assert workflow["on"] == %{"workflow_call" => nil}
    refute Map.has_key?(caller["jobs"]["ehos"], "secrets")
  end

  test "asks for no permission its caller does not grant, and keeps no concurrency of its own",
       %{workflow: workflow, caller: caller} do
    granted = caller["permissions"]

    for {job, definition} <- workflow["jobs"], {scope, level} <- definition["permissions"] do
      assert {job, granted[scope]} == {job, level}
    end

    refute Map.has_key?(workflow, "concurrency")
    assert for({job, %{"concurrency" => _}} <- workflow["jobs"], do: job) == []
    assert Map.has_key?(caller, "concurrency")
  end

  test "is the workflow the caller names" do
    {:ok, ref} = InitService.ref("1.2.3", String.duplicate("a", 40))

    assert InitService.workflow("invoice-pdf", ref) =~
             "uses: EmpoweredHouse/ehos-tools/#{@path}@#{ref}\n"
  end
end
