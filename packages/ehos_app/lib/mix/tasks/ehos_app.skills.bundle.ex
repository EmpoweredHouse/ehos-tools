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

      {files, source} = bundle(plugin, checkout)
      root = Path.join("priv/skills", name)

      for {path, content} <- files do
        destination = Path.join(root, path)
        File.mkdir_p!(Path.dirname(destination))
        File.write!(destination, content)
      end

      File.write!(Path.join(root, "source.json"), JSON.encode!(source) <> "\n")
    end

    def run(_args),
      do: Mix.raise("Usage: mix ehos_app.skills.bundle <plugin-name> <source-checkout>")

    @doc """
    Reads a pinned plugin's files and provenance from a checkout, without writing them.

    `opts[:git]` selects the `EhosApp.SkillGit` implementation, defaulting to `EhosApp.SkillGitImpl`.
    Raises `Mix.Error` for a failed read, a different plugin version or an empty skill tree.
    """
    @spec bundle(map(), Path.t(), keyword()) :: {map(), map()}
    def bundle(plugin, checkout, opts \\ []) do
      git = Keyword.get(opts, :git, EhosApp.SkillGitImpl)
      prefix = "plugins/#{plugin.name}/"

      manifest =
        git!(git, checkout, ["show", "#{plugin.commit}:#{prefix}.claude-plugin/plugin.json"])
        |> JSON.decode!()

      unless manifest["name"] == plugin.name and manifest["version"] == plugin.version,
        do: Mix.raise("Pinned commit does not contain the configured plugin version")

      files =
        git
        |> git!(checkout, [
          "ls-tree",
          "-r",
          "--name-only",
          plugin.commit,
          "--",
          prefix <> "skills/"
        ])
        |> String.split("\n", trim: true)
        |> Map.new(fn path ->
          {String.replace_prefix(path, prefix <> "skills/", ""),
           git!(git, checkout, ["show", "#{plugin.commit}:#{path}"])}
        end)

      if map_size(files) == 0, do: Mix.raise("Pinned commit contains no skills")

      source = %{
        "name" => plugin.name,
        "repo" => plugin.repo,
        "ref" => plugin.ref,
        "commit" => plugin.commit,
        "files" =>
          Map.new(files, fn {path, content} ->
            {path, :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)}
          end)
      }

      {files, source}
    end

    defp git!(git, checkout, args) do
      case git.run(args, checkout) do
        {:ok, output} ->
          output

        {:error, _reason} ->
          Mix.raise("Cannot read the pinned plugin commit from the source checkout")
      end
    end
  end
end
