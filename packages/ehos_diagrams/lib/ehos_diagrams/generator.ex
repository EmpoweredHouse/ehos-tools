defmodule EhosDiagrams.Generator do
  @moduledoc """
  A directory of sources, written into a directory of outputs with the fonts' licences beside
  them (eh-os D-107): what `mix ehos_diagrams.gen` does, for a host that writes its own task.

      design = EhosDiagrams.design()
      {:ok, wanted} = Generator.outputs("docs/diagrams", "docs/img", design, vocabulary)
      orphans = Generator.orphans(wanted, "docs/img")

      # Writing:
      Generator.write(wanted, orphans)
      # Checking: both lists empty.
      {Generator.stale(wanted), orphans}

  The paths are the host's, read as they are given, and every output names its source by the path
  it was read from.
  """

  @typedoc """
  What `mix ehos_diagrams.gen` reads from the host's `mix.exs`, under `ehos_diagrams:` in
  `project/0`:

    * `:sources` and `:out`: the directories of the sources and of the outputs;
    * `:vocabulary`: the `t:EhosDiagrams.vocabulary/0`, or `{module, function, args}` that returns
      it, called after the host is compiled;
    * `:pages`: wildcards of the pages that must link every output, none unless given;
    * `:documents`: wildcards of the documents that may hold no Mermaid block, none unless given;
    * `:record`: the decision record an output cites, none unless given.
  """
  @type config :: [
          sources: Path.t(),
          out: Path.t(),
          vocabulary: EhosDiagrams.vocabulary() | {module(), atom(), list()},
          pages: [String.t()],
          documents: [String.t()],
          record: String.t()
        ]

  @doc """
  What `mix ehos_diagrams.gen` does for a host's `config`, in the host's `ehos_design` unless
  `design` is given: with `check?`, `{:ok, message}` when every output is current, its pages link
  it and no document holds a Mermaid block; without it, the same after writing the outputs and
  removing the orphans. `{:error, message}` names each thing wrong, a line each.
  """
  @spec run(config(), boolean(), EhosDiagrams.design() | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  def run(config, check?, design \\ nil) do
    sources = Keyword.fetch!(config, :sources)
    out = Keyword.fetch!(config, :out)
    vocabulary = vocabulary(Keyword.fetch!(config, :vocabulary))
    opts = [generator: "mix ehos_diagrams.gen"] ++ Keyword.take(config, [:record])

    with {:ok, wanted} <-
           rendered(sources, out, design || EhosDiagrams.design(), vocabulary, opts),
         :ok <- current(wanted, check?),
         do: report(wanted, config, check?)
  end

  # Writing removes an output whose source is gone; checking reports it.
  defp report(wanted, config, check?) do
    out = Keyword.fetch!(config, :out)
    orphans = orphans(wanted, out)
    unless check?, do: write(wanted, orphans)
    reported = if check?, do: Enum.map(orphans, &"#{&1} has no source"), else: []
    pages = EhosDiagrams.Pages.problems(wildcard(config[:pages]), out)
    mermaid = EhosDiagrams.Pages.mermaid(wildcard(config[:documents]))
    count = map_size(wanted) - length(EhosDiagrams.licences())

    case reported ++ pages ++ mermaid do
      [] -> {:ok, "#{count} diagrams in #{out} are up to date"}
      problems -> {:error, Enum.join(problems, "\n")}
    end
  end

  # Called after the host is compiled, so its module is loaded; the function is the host's own.
  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp vocabulary({module, function, args}), do: apply(module, function, args)
  defp vocabulary(%{} = vocabulary), do: vocabulary

  defp rendered(sources, out, design, vocabulary, opts) do
    case outputs(sources, out, design, vocabulary, opts) do
      {:ok, wanted} -> {:ok, wanted}
      {:error, refused} -> {:error, Enum.join(refused, "\n")}
    end
  end

  defp current(_wanted, false), do: :ok

  defp current(wanted, true) do
    case stale(wanted) do
      [] ->
        :ok

      stale ->
        {:error,
         "#{Enum.join(stale, ", ")} differ from their sources. Run `mix ehos_diagrams.gen` and " <>
           "commit them."}
    end
  end

  defp wildcard(nil), do: []

  defp wildcard(patterns),
    do: patterns |> Enum.flat_map(&Path.wildcard/1) |> Enum.uniq() |> Enum.sort()

  @doc """
  Each output by its path, with the licences: `{:ok, wanted}`, or `{:error, reasons}` naming
  everything a source holds that is refused, by the source's path. `opts` are
  `EhosDiagrams.render/5`'s, with `:source` set to each source's path.
  """
  @spec outputs(
          Path.t(),
          Path.t(),
          EhosDiagrams.design(),
          EhosDiagrams.vocabulary(),
          [EhosDiagrams.option()]
        ) :: {:ok, %{Path.t() => String.t()}} | {:error, [String.t()]}
  def outputs(sources, out, design, vocabulary, opts \\ []) do
    results =
      for source <- sources |> Path.join("*.svg") |> Path.wildcard() |> Enum.sort() do
        id = Path.basename(source, ".svg")
        opts = Keyword.put(opts, :source, source)
        {id, EhosDiagrams.render(File.read!(source), id, design, vocabulary, opts)}
      end

    case for {id, {:error, reasons}} <- results,
             reason <- reasons,
             do: "#{sources}/#{id}.svg holds #{reason}" do
      [] -> {:ok, Map.merge(written(results, out), licences(out, design))}
      refused -> {:error, refused}
    end
  end

  defp written(results, out),
    do: for({id, {:ok, svg}} <- results, into: %{}, do: {Path.join(out, id <> ".svg"), svg})

  defp licences(out, design) do
    Map.new(
      EhosDiagrams.licences(),
      &{Path.join(out, &1), File.read!(Path.join(design.fonts, &1))}
    )
  end

  @doc "The outputs whose file is not what they should be, sorted: edited by hand, or not written."
  @spec stale(%{Path.t() => String.t()}) :: [Path.t()]
  def stale(wanted),
    do: for({path, content} <- Enum.sort(wanted), File.read(path) != {:ok, content}, do: path)

  @doc "The SVG files in `out` that no source writes, sorted: left behind by a source removed."
  @spec orphans(%{Path.t() => String.t()}, Path.t()) :: [Path.t()]
  def orphans(wanted, out) do
    for output <- out |> Path.join("*.svg") |> Path.wildcard() |> Enum.sort(),
        not Map.has_key?(wanted, output),
        do: output
  end

  @doc "Writes each output that differs, and removes the orphans."
  @spec write(%{Path.t() => String.t()}, [Path.t()]) :: :ok
  def write(wanted, orphans) do
    Enum.each(orphans, &File.rm!/1)

    Enum.each(wanted, fn {path, content} ->
      File.mkdir_p!(Path.dirname(path))
      if File.read(path) != {:ok, content}, do: File.write!(path, content)
    end)
  end
end
