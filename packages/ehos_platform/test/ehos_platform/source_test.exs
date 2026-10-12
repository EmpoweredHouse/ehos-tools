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

  # Whatever modes the archive gives (`git archive` gives 0664), nobody but the owner may change a
  # module between its check and OpenTofu running it.
  test "the modules are the owner's alone once unpacked", %{
    archive: archive,
    sha256: sha256,
    into: into
  } do
    assert {:ok, _source} = Source.release(chart: @chart, modules: {archive, sha256}, into: into)

    for path <- [into | Path.wildcard(Path.join(into, "**"), match_dot: true)] do
      %File.Stat{mode: mode} = File.stat!(path)
      assert Bitwise.band(mode, 0o077) == 0, "#{path}: #{Integer.to_string(mode, 8)}"
    end
  end

  test "replaces the modules an earlier release unpacked", %{
    archive: archive,
    sha256: sha256,
    into: into
  } do
    assert {:ok, _source} = Source.release(chart: @chart, modules: {archive, sha256}, into: into)
    assert {:ok, _source} = Source.release(chart: @chart, modules: {archive, sha256}, into: into)
    assert File.ls!(into) == ["deploy"]
    assert File.ls!(Path.dirname(into)) |> Enum.filter(&String.starts_with?(&1, "modules.")) == []
  end

  test "refuses a file, or a directory that holds anything but modules, as where to unpack",
       %{archive: archive, sha256: sha256, tmp_dir: dir} do
    file = Path.join(dir, "a-file")
    File.write!(file, "kept")
    installations = Path.join(dir, "ehos")
    File.mkdir_p!(Path.join(installations, "trial"))

    for into <- [file, installations] do
      assert {:error, message} =
               Source.release(chart: @chart, modules: {archive, sha256}, into: into)

      assert message =~ "holds something else"
    end

    assert File.read!(file) == "kept"
    assert File.dir?(Path.join(installations, "trial"))
  end

  test "refuses to empty a directory that holds more than the modules",
       %{archive: archive, sha256: sha256, tmp_dir: dir} do
    for into <- ["/", "~", File.cwd!(), dir] do
      assert {:error, message} =
               Source.release(chart: @chart, modules: {archive, sha256}, into: into)

      assert message =~ "are not unpacked into"
    end

    assert File.exists?(archive)
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
