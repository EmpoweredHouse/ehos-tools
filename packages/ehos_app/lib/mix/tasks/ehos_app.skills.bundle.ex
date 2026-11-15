if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.EhosApp.Skills.Bundle do
    @moduledoc """
    Refreshes a plugin's bundled sources from its pinned commit in a local git checkout.

    Run from the `ehos_app` package: `mix ehos_app.skills.bundle <plugin-name> <source-checkout>`.
    The checkout need not have that commit checked out. No files from the working tree or a
    Claude cache are read. Commit the resulting source files and `source.json` together.
    """
    use Mix.Task

    @shortdoc "Refreshes a pinned skill bundle from its source repository"

    @doc false
    @impl Mix.Task
    def run([name, checkout]) do
      plugin = Enum.find(Mix.Tasks.EhosApp.Install.plugins(), &(&1.name == name))
      unless plugin, do: Mix.raise("Unknown plugin")

      unless File.regular?("lib/ehos_app/skills.ex"),
        do: Mix.raise("Run from the ehos_app package")

      prefix = "plugins/#{name}/"

      manifest =
        git!(checkout, ["show", "#{plugin.commit}:#{prefix}.claude-plugin/plugin.json"])
        |> JSON.decode!()

      unless manifest["name"] == name and manifest["version"] == plugin.version,
        do: Mix.raise("Pinned commit does not contain the configured plugin version")

      files =
        checkout
        |> git!(["ls-tree", "-r", "--name-only", plugin.commit, "--", prefix <> "skills/"])
        |> String.split("\n", trim: true)
        |> Map.new(fn path ->
          {String.replace_prefix(path, prefix <> "skills/", ""),
           git!(checkout, ["show", "#{plugin.commit}:#{path}"])}
        end)

      if map_size(files) == 0, do: Mix.raise("Pinned commit contains no skills")
      root = Path.join("priv/skills", name)

      for {path, content} <- files do
        destination = Path.join(root, path)
        File.mkdir_p!(Path.dirname(destination))
        File.write!(destination, content)
      end

      source = %{
        "name" => name,
        "repo" => plugin.repo,
        "ref" => plugin.ref,
        "commit" => plugin.commit,
        "files" =>
          Map.new(files, fn {path, content} ->
            {path, :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)}
          end)
      }

      File.write!(Path.join(root, "source.json"), JSON.encode!(source) <> "\n")
    end

    def run(_args),
      do: Mix.raise("Usage: mix ehos_app.skills.bundle <plugin-name> <source-checkout>")

    defp git!(checkout, args) do
      case System.cmd("git", ["-C", checkout | args], stderr_to_stdout: true) do
        {output, 0} -> output
        _failure -> Mix.raise("Cannot read the pinned plugin commit from the source checkout")
      end
    end
  end
end
