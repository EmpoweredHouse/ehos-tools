defmodule EhosPlatform.SourceTest do
  use ExUnit.Case, async: true

  alias EhosPlatform.Source

  doctest Source

  @moduletag :tmp_dir

  @chart "oci://ghcr.io/empoweredhouse/charts/ehos@sha256:" <> String.duplicate("1e", 32)

  # What a release attaches: deploy/tofu as `git archive` writes it, with the directories above it
  # and the pax global header that names the commit.
  setup %{tmp_dir: dir} do
    repository = Path.join(dir, "repository")
    File.mkdir_p!(Path.join(repository, "deploy/tofu/oci"))
    File.mkdir_p!(Path.join(repository, "deploy/tofu/cloud-init"))
    File.write!(Path.join(repository, "deploy/tofu/oci/main.tf"), "# oci\n")
    File.write!(Path.join(repository, "deploy/tofu/cloud-init/k3s.yaml.tftpl"), "#cloud-config\n")
    git!(repository, ["init", "--quiet"])
    git!(repository, ["add", "--all"])
    git!(repository, ["commit", "--quiet", "--message", "modules"])

    archive = Path.join(dir, "ehos-modules.tar.gz")
    git!(repository, ["archive", "--format=tar.gz", "--output", archive, "HEAD", "deploy/tofu"])

    %{archive: archive, sha256: sha256(archive), into: Path.join(dir, "modules")}
  end

  test "a release's modules are unpacked once their SHA-256 matches, in the checkout's layout",
       %{archive: archive, sha256: sha256, into: into} do
    assert {:ok, source} = Source.release(chart: @chart, modules: {archive, sha256}, into: into)

    assert source.chart == {:oci, @chart}
    assert Source.module(source, "oci") == Path.join(into, "deploy/tofu/oci")
    assert File.read!(Path.join(into, "deploy/tofu/oci/main.tf")) == "# oci\n"
    assert File.exists?(Path.join(into, "deploy/tofu/cloud-init/k3s.yaml.tftpl"))
    refute File.exists?(Path.join(into, "pax_global_header"))
  end

  test "an archive whose SHA-256 is not the release's is refused, and nothing is unpacked",
       %{archive: archive, into: into} do
    other = String.duplicate("0", 64)

    assert {:error, message} =
             Source.release(chart: @chart, modules: {archive, other}, into: into)

    assert message =~ "not #{other}, which the release names"
    refute File.exists?(into)
  end

  test "a chart not named by digest is refused", %{archive: archive, sha256: sha256, into: into} do
    for chart <- ["oci://ghcr.io/empoweredhouse/charts/ehos:0.5.0", "ghcr.io/x@sha256:" <> sha256] do
      assert {:error, message} =
               Source.release(chart: chart, modules: {archive, sha256}, into: into)

      assert message =~ "named by digest"
    end
  end

  test "an archive that would write outside deploy/tofu/, or a link, is refused unpacked",
       %{tmp_dir: dir, into: into} do
    for {name, entries} <- [
          {"outside", [{~c"deploy/elsewhere.tf", "#"}]},
          {"escape", [{~c"deploy/tofu/../../escape.tf", "#"}]}
        ] do
      archive = Path.join(dir, "#{name}.tar.gz")
      :ok = :erl_tar.create(String.to_charlist(archive), entries, [:compressed])

      assert {:error, message} =
               Source.release(chart: @chart, modules: {archive, sha256(archive)}, into: into)

      assert message =~ "not a file or directory under deploy/tofu/"
      refute File.exists?(into)
    end

    linked = Path.join(dir, "linked")
    File.mkdir_p!(Path.join(linked, "deploy/tofu"))
    File.ln_s!("/etc/passwd", Path.join(linked, "deploy/tofu/link"))
    archive = Path.join(dir, "link.tar.gz")

    {_, 0} =
      System.cmd("tar", ["-czf", archive, "-C", linked, "deploy"],
        env: [{"COPYFILE_DISABLE", "1"}]
      )

    assert {:error, message} =
             Source.release(chart: @chart, modules: {archive, sha256(archive)}, into: into)

    assert message =~ "deploy/tofu/link"
  end

  test "a file that is not an archive, or is not there, is refused", %{tmp_dir: dir, into: into} do
    plain = Path.join(dir, "plain.tar.gz")
    File.write!(plain, "not an archive")

    assert {:error, message} =
             Source.release(chart: @chart, modules: {plain, sha256(plain)}, into: into)

    assert message =~ "is not a .tar.gz"

    missing = Path.join(dir, "missing.tar.gz")

    assert {:error, message} =
             Source.release(
               chart: @chart,
               modules: {missing, String.duplicate("0", 64)},
               into: into
             )

    assert message =~ "Could not read"
  end

  defp sha256(path), do: :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)

  # The user's own git configuration is left out: no signing, no hooks, a fixed author.
  defp git!(repository, args) do
    config =
      ~w(-c user.name=EHOS -c user.email=ehos@example.com -c commit.gpgsign=false -c core.hooksPath=/dev/null)

    {output, 0} = System.cmd("git", ["-C", repository | config ++ args], stderr_to_stdout: true)
    output
  end
end
