defmodule Mix.Tasks.EhosDiagrams.Gen do
  @shortdoc "Generates a host's diagrams from their sources"

  @moduledoc """
  Writes each diagram source of the host into its output, in `ehos_design`'s colours and fonts,
  light and dark, with the fonts' licences beside them (eh-os D-107, T-21).

      $ mix ehos_diagrams.gen          # writes the outputs, and removes those with no source
      $ mix ehos_diagrams.gen --check  # fails if an output differs from its source or has none,
                                       # a source breaks a rule, a page links an image that does
                                       # not exist, no page links an output, or a document holds
                                       # a Mermaid block

  It reads the host's `mix.exs`, `ehos_diagrams:` in `project/0`
  (`t:EhosDiagrams.Generator.config/0`):

      ehos_diagrams: [
        sources: "docs/diagrams",
        out: "docs/img",
        vocabulary: {MyProject.Docs, :vocabulary, []},
        pages: ["README.md", "docs/**/*.md"],
        documents: ["docs/**/*.md"]
      ]

  Run `--check` in the host's gate, so an output edited by hand or left behind by its source fails
  CI. A host with more to check writes its own task on `EhosDiagrams.Generator`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _args} = OptionParser.parse!(args, strict: [check: :boolean])

    config =
      Mix.Project.config()[:ehos_diagrams] ||
        Mix.raise(
          "mix ehos_diagrams.gen reads ehos_diagrams: in the project's mix.exs, and it has none"
        )

    # The vocabulary may be the host's own function, and ehos_design's priv directory is read
    # from the host's loaded applications.
    Mix.Task.run("compile")
    Mix.Task.run("loadpaths")

    case EhosDiagrams.Generator.run(config, opts[:check] == true) do
      {:ok, message} -> Mix.shell().info(message)
      {:error, message} -> Mix.raise(message)
    end
  end
end
