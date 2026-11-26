defmodule Mix.Tasks.EhosApp.InstallTest.LinkedFiles do
  # A file the installer replaces while it is still what a generator wrote, reached through a
  # symbolic link: Igniter would write through the link into another checkout's file. The links
  # are real ones, in a directory the test changes into: the installer reads them relative to the
  # working directory, as it runs in the project's root. The module is not async, so ExUnit runs
  # it after every async module, and no other test sees the changed working directory.
  use Mix.Tasks.EhosApp.InstallCase, async: false

  @moduletag :tmp_dir

  @ci ".github/workflows/ci.yml"
  @pull_request_template ".github/pull_request_template.md"

  describe "a file reached through a symbolic link" do
    test "leaves a CI workflow an earlier version wrote, linked to another file, and says so",
         %{tmp_dir: dir} do
      earlier = File.read!("test/fixtures/ci_workflows/0.38.0.yml")
      File.mkdir_p!(Path.join(dir, "other/.github/workflows"))
      File.write!(Path.join(dir, "other/#{@ci}"), earlier)
      File.mkdir_p!(Path.join(dir, "shop/.github/workflows"))
      File.ln_s!("../../../other/#{@ci}", Path.join(dir, "shop/#{@ci}"))

      File.cd!(Path.join(dir, "shop"), fn ->
        igniter = phx_test_project() |> with_file(@ci, earlier) |> run_installer()

        assert content(igniter, @ci) == earlier
        assert notices_on(igniter, @ci) == [linked(@ci, "an earlier version of ehos_app")]

        again = igniter |> apply_igniter!() |> run_installer()
        assert content(again, @ci) == earlier
        assert notices_on(again, @ci) == [linked(@ci, "an earlier version of ehos_app")]
      end)

      assert File.read!(Path.join(dir, "other/#{@ci}")) == earlier
    end

    test "leaves files an earlier version wrote in a linked directory, and says so",
         %{tmp_dir: dir} do
      workflow = File.read!("test/fixtures/ci_workflows/0.38.0.yml")
      template = File.read!("test/fixtures/pull_request_template_0.27.0.md")
      File.mkdir_p!(Path.join(dir, "shared/workflows"))
      File.write!(Path.join(dir, "shared/workflows/ci.yml"), workflow)
      File.write!(Path.join(dir, "shared/pull_request_template.md"), template)
      File.mkdir_p!(Path.join(dir, "shop"))
      File.ln_s!("../shared", Path.join(dir, "shop/.github"))

      File.cd!(Path.join(dir, "shop"), fn ->
        igniter =
          phx_test_project()
          |> with_file(@ci, workflow)
          |> with_file(@pull_request_template, template)
          |> run_installer()

        assert {content(igniter, @ci), content(igniter, @pull_request_template)} ==
                 {workflow, template}

        assert notices_on(igniter, @ci) ++ notices_on(igniter, @pull_request_template) == [
                 linked(@ci, "an earlier version of ehos_app"),
                 linked(@pull_request_template, "an earlier version of ehos_app")
               ]
      end)
    end

    test "writes no file into a linked directory that lacks it, and says so", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "shared"))
      File.mkdir_p!(Path.join(dir, "shop"))
      File.ln_s!("../shared", Path.join(dir, "shop/.github"))

      File.cd!(Path.join(dir, "shop"), fn ->
        igniter = run_installer(phx_test_project())

        refute Igniter.exists?(igniter, @ci)
        refute Igniter.exists?(igniter, @pull_request_template)

        assert notices_on(igniter, @ci) ++ notices_on(igniter, @pull_request_template) == [
                 unwritten(@ci),
                 unwritten(@pull_request_template)
               ]
      end)

      assert File.ls!(Path.join(dir, "shared")) == []
    end

    test "writes no CI workflow through a link that points to nothing, and says so",
         %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "other/.github/workflows"))
      File.mkdir_p!(Path.join(dir, "shop/.github/workflows"))
      File.ln_s!("../../../other/#{@ci}", Path.join(dir, "shop/#{@ci}"))

      File.cd!(Path.join(dir, "shop"), fn ->
        igniter = run_installer(phx_test_project())

        refute Igniter.exists?(igniter, @ci)
        assert notices_on(igniter, @ci) == [unwritten(@ci)]
      end)
    end

    test "leaves Phoenix's home page when it is linked, and says so", %{tmp_dir: dir} do
      home = "lib/test_web/controllers/page_html/home.html.heex"
      page = phx_test_project() |> content(home)
      File.mkdir_p!(Path.join(dir, "other"))
      File.write!(Path.join(dir, "other/home.html.heex"), page)
      File.mkdir_p!(Path.join(dir, "shop/#{Path.dirname(home)}"))
      File.ln_s!(Path.join(dir, "other/home.html.heex"), Path.join(dir, "shop/#{home}"))

      File.cd!(Path.join(dir, "shop"), fn ->
        igniter = run_installer(phx_test_project())

        assert content(igniter, home) == page
        assert notices_on(igniter, home) == [linked(home, "Phoenix")]
      end)
    end
  end

  defp run_installer(igniter), do: Igniter.compose_task(igniter, "ehos_app.install", [])

  defp notices_on(igniter, path),
    do: Enum.filter(igniter.notices, &String.starts_with?(&1, path <> " "))

  defp linked(path, written_by),
    do: """
    #{path} is still as #{written_by} wrote it, but it is reached through a
    symbolic link, so the installer did not replace it: the file the link points to can be
    another checkout's. To take this version's file, replace the link with a copy of what it
    points to, then run `mix ehos_app.install` again.
    """

  defp unwritten(path),
    do: """
    #{path} was not written: it is reached through a symbolic link, so the file would be
    written where the link points, which can be another checkout. To have this version's
    file, replace the link with a file or a directory of the project's own, then run
    `mix ehos_app.install` again.
    """
end
