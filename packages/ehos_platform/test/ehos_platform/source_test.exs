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

  describe "release/1" do
    test "unpacks a release's modules once their SHA-256 matches, in the checkout's layout",
         %{archive: archive, sha256: sha256, into: into} do
      assert Source.release(chart: @chart, modules: {archive, sha256}, into: into) ==
               {:ok, %Source{chart: {:oci, @chart}, modules: into}}

      assert Source.module(%Source{chart: {:oci, @chart}, modules: into}, "oci") ==
               Path.join(into, "deploy/tofu/oci")

      assert files(into) == %{
               "deploy/tofu/cloud-init/k3s.yaml.tftpl" => "#cloud-config\n",
               "deploy/tofu/oci/main.tf" => "# oci\n"
             }
    end

    # Whatever modes the archive gives (`git archive` gives 0664), nobody but the owner may change a
    # module between its check and OpenTofu running it.
    test "leaves the modules the owner's alone once unpacked",
         %{archive: archive, sha256: sha256, into: into} do
      {:ok, _source} = Source.release(chart: @chart, modules: {archive, sha256}, into: into)

      paths = [into | Path.wildcard(Path.join(into, "**"), match_dot: true)]

      assert Enum.reject(paths, &(Bitwise.band(File.stat!(&1).mode, 0o077) == 0)) == []
    end

    test "replaces the modules an earlier release unpacked",
         %{archive: archive, sha256: sha256, into: into} do
      {:ok, _source} = Source.release(chart: @chart, modules: {archive, sha256}, into: into)
      File.write!(Path.join(into, "deploy/tofu/oci/left-behind.tf"), "#")

      assert Source.release(chart: @chart, modules: {archive, sha256}, into: into) ==
               {:ok, %Source{chart: {:oci, @chart}, modules: into}}

      assert files(into) == %{
               "deploy/tofu/cloud-init/k3s.yaml.tftpl" => "#cloud-config\n",
               "deploy/tofu/oci/main.tf" => "# oci\n"
             }

      assert File.ls!(Path.dirname(into)) |> Enum.sort() ==
               ["ehos-modules.tar.gz", "modules", "repository"]
    end

    test "refuses a file, or a directory that holds anything but modules, as where to unpack",
         %{archive: archive, sha256: sha256, tmp_dir: dir} do
      file = Path.join(dir, "a-file")
      File.write!(file, "kept")
      installations = Path.join(dir, "ehos")
      File.mkdir_p!(Path.join(installations, "trial"))

      for into <- [file, installations] do
        assert Source.release(chart: @chart, modules: {archive, sha256}, into: into) ==
                 {:error,
                  "The modules are not unpacked into #{into}, which holds something else; " <>
                    "give a directory of their own"}
      end

      assert File.read!(file) == "kept"
      assert File.ls!(installations) == ["trial"]
    end

    test "refuses to empty a directory that holds the archive",
         %{archive: archive, sha256: sha256, tmp_dir: dir} do
      for into <- [File.cwd!(), dir] do
        assert Source.release(chart: @chart, modules: {archive, sha256}, into: into) ==
                 {:error, "The modules are not unpacked into #{into}, which holds the archive"}
      end

      assert File.exists?(archive)
    end

    test "refuses to empty the root or the home directory",
         %{archive: archive, sha256: sha256} do
      assert Source.release(chart: @chart, modules: {archive, sha256}, into: "/") ==
               {:error,
                "The modules are not unpacked into /, which holds something else; " <>
                  "give a directory of their own"}

      # `~` is the home directory, which holds the archive when the checkout is under it, as on a
      # developer's machine and in CI, and something else when it is not.
      home = Path.expand("~")

      assert Source.release(chart: @chart, modules: {archive, sha256}, into: "~") in [
               {:error, "The modules are not unpacked into #{home}, which holds the archive"},
               {:error,
                "The modules are not unpacked into #{home}, which holds something else; " <>
                  "give a directory of their own"}
             ]

      assert File.exists?(archive)
    end

    test "refuses an archive whose SHA-256 is not the release's, and unpacks nothing",
         %{archive: archive, sha256: sha256, into: into} do
      other = String.duplicate("0", 64)

      assert Source.release(chart: @chart, modules: {archive, other}, into: into) ==
               {:error,
                "#{archive} has the SHA-256 #{sha256}, not #{other}, which the release names; " <>
                  "nothing was unpacked"}

      refute File.exists?(into)
    end

    test "refuses a chart not named by digest", %{archive: archive, sha256: sha256, into: into} do
      for chart <- [
            "oci://ghcr.io/empoweredhouse/charts/ehos:0.5.0",
            "ghcr.io/x@sha256:" <> sha256
          ] do
        assert Source.release(chart: chart, modules: {archive, sha256}, into: into) ==
                 {:error,
                  "The chart is named by digest, oci://<repository>@sha256:<64 hex>, not #{chart}"}
      end
    end

    test "refuses, unpacking nothing, an archive that would write outside deploy/tofu/",
         %{tmp_dir: dir, into: into} do
      for {name, entry} <- [
            {"outside", ~c"deploy/elsewhere.tf"},
            {"escape", ~c"deploy/tofu/../../escape.tf"}
          ] do
        archive = Path.join(dir, "#{name}.tar.gz")
        :ok = :erl_tar.create(String.to_charlist(archive), [{entry, "#"}], [:compressed])

        assert Source.release(chart: @chart, modules: {archive, sha256(archive)}, into: into) ==
                 {:error,
                  "#{archive} holds what is not a file or directory under deploy/tofu/: #{entry}"}

        refute File.exists?(into)
      end
    end

    test "refuses, unpacking nothing, an archive that holds a link", %{tmp_dir: dir, into: into} do
      linked = Path.join(dir, "linked")
      File.mkdir_p!(Path.join(linked, "deploy/tofu"))
      File.ln_s!("/etc/passwd", Path.join(linked, "deploy/tofu/link"))
      archive = Path.join(dir, "link.tar.gz")

      {_, 0} =
        System.cmd("tar", ["-czf", archive, "-C", linked, "deploy"],
          env: [{"COPYFILE_DISABLE", "1"}]
        )

      assert Source.release(chart: @chart, modules: {archive, sha256(archive)}, into: into) ==
               {:error,
                "#{archive} holds what is not a file or directory under deploy/tofu/: " <>
                  "deploy/tofu/link"}

      refute File.exists?(into)
    end

    test "refuses a file that is not an archive", %{tmp_dir: dir, into: into} do
      plain = Path.join(dir, "plain.tar.gz")
      File.write!(plain, "not an archive")

      assert Source.release(chart: @chart, modules: {plain, sha256(plain)}, into: into) ==
               {:error, "#{plain} is not a .tar.gz: :eof"}
    end

    test "refuses an archive that is not there", %{tmp_dir: dir, into: into} do
      missing = Path.join(dir, "missing.tar.gz")

      assert Source.release(
               chart: @chart,
               modules: {missing, String.duplicate("0", 64)},
               into: into
             ) == {:error, "Could not read #{missing}: no such file or directory"}
    end
  end

  # Every file under `dir`, by its path relative to it, with its contents.
  defp files(dir) do
    for path <- Path.wildcard(Path.join(dir, "**"), match_dot: true),
        File.regular?(path),
        into: %{},
        do: {Path.relative_to(path, dir), File.read!(path)}
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
