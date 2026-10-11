defmodule Mix.Tasks.Ehosctl.ReleaseFile do
  @shortdoc "Writes a release's release.json: what this ehosctl is and what it creates from"

  @moduledoc """
  Writes `release.json` for a release of `ehosctl` (eh-os D-91): its version and commit, the
  interfaces it produces and accepts, and the `ehos_app` it creates applications from, as
  `Ehosctl.Version.release/1` describes them.

      $ mix ehosctl.release_file --commit <sha> --output burrito_out/release.json

  CI's `build` job runs it beside the binaries, so the file describes the build that is published.

  ## Options

    * `--commit` - the full commit the release is built from (required).
    * `--output` - where to write it; `release.json` by default.
  """

  use Mix.Task

  @switches [commit: :string, output: :string]

  @impl Mix.Task
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: @switches)
    commit = opts[:commit]

    if rest != [] or not is_binary(commit) do
      Mix.raise("Usage: mix ehosctl.release_file --commit <sha> [--output <path>]")
    end

    # The commit a tag names, in full, as git prints it: a short one could name another later.
    unless commit =~ ~r/\A[0-9a-f]{40}\z/ do
      Mix.raise("--commit is a full commit, 40 hexadecimal digits, not #{inspect(commit)}")
    end

    Mix.Task.run("compile")
    # Loaded, not started: starting `ehosctl` runs the command line and halts the VM.
    :ok = Application.ensure_loaded(:ehosctl)

    output = Keyword.get(opts, :output, "release.json")
    File.write!(output, [JSON.encode!(Ehosctl.Version.release(commit: commit)), ?\n])
    Mix.shell().info("wrote #{output}")
  end
end
