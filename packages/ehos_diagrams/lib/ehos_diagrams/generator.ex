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

  The paths are the host's. Every output names its source by its path from the current directory,
  so the sources are under it.
  """

  @typedoc """
  What `mix ehos_diagrams.gen` reads from the host's `mix.exs`, under `ehos_diagrams:` in
  `project/0`:

    * `:sources` and `:out`: the directories of the sources and of the outputs;
    * `:vocabulary`: the `t:EhosDiagrams.vocabulary/0`, or `{module, function, args}` that returns
      it, called after the host is compiled;
    * `:pages`: wildcards of the pages that must link every output; without it, or with none, no
      output has to be linked;
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
    pages = pages(config[:pages], Map.keys(wanted))
    mermaid = EhosDiagrams.Pages.mermaid(wildcard(config[:documents]))
    count = map_size(wanted) - length(EhosDiagrams.licences())

    case reported ++ pages ++ mermaid do
      [] -> {:ok, "#{count} diagrams in #{out} are up to date"}
      problems -> {:error, Enum.join(problems, "\n")}
    end
  end

  defp pages(nil, _outputs), do: []
  defp pages([], _outputs), do: []

  defp pages(patterns, outputs),
    do:
      EhosDiagrams.Pages.problems(wildcard(patterns), Enum.filter(outputs, &(&1 =~ ~r/\.svg\z/)))

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
  `EhosDiagrams.render/5`'s, with `:source` set to each source's path relative to the current
  directory, so an output names no machine's own path. Refused when `sources` is not a directory or
  holds no source, where every output would be an orphan, when `sources` and `out` are one
  directory, by path or through a link, where the outputs would overwrite the sources, and when
  `sources` is outside the current directory, whose path would differ from one machine to another,
  or when its path or a source's holds `--`, which the comment that names it in an output cannot.
  The outputs' directory is refused outside the current directory, named through `..`, or when it or
  a directory above it, below the current one, is a symbolic link, which the refusal names. An
  output that is a link, symbolic or to a source, is refused, since writing it would write what it
  points at; so is a licence that is a link, or not a file of its own, unless it is a file that
  already holds that licence, which writing leaves alone.
  """
  @spec outputs(
          Path.t(),
          Path.t(),
          EhosDiagrams.design(),
          EhosDiagrams.vocabulary(),
          [EhosDiagrams.option()]
        ) :: {:ok, %{Path.t() => String.t()}} | {:error, [String.t()]}
  def outputs(sources, out, design, vocabulary, opts \\ []) do
    case sources_refusal(sources, out) || outputs_refusal(out) do
      nil -> render_all(sources, out, design, vocabulary, opts)
      refusal -> {:error, [refusal]}
    end
  end

  # The sources' directory and each source as an output names it, from the current directory.
  defp sources_refusal(sources, out) do
    named = Path.relative_to_cwd(Path.expand(sources))

    cond do
      not File.dir?(sources) ->
        "#{sources}, which is not a directory of sources"

      same_directory?(sources, out) ->
        "#{out}, the sources' own directory, for the outputs"

      Path.type(named) == :absolute ->
        "#{sources}, a directory of sources outside #{File.cwd!()}"

      # Each output names its source in an XML comment, which "--" would end.
      dashed = Enum.find([sources | Path.wildcard(Path.join(sources, "*.svg"))], &dashed?/1) ->
        ~s(#{dashed}, a path an output names in a comment, which cannot hold "--")

      Path.wildcard(Path.join(sources, "*.svg")) == [] ->
        "#{sources}, which holds no source"

      true ->
        nil
    end
  end

  defp dashed?(path),
    do: path |> Path.expand() |> Path.relative_to_cwd() |> String.contains?("--")

  defp outputs_refusal(out) do
    named = Path.relative_to_cwd(Path.expand(out))

    cond do
      # Checked as written, since the system climbs out of a link that ".." follows.
      ".." in Path.split(out) ->
        ~s(#{out}, a directory of outputs named through "..")

      Path.type(named) == :absolute ->
        "#{out}, a directory of outputs outside #{File.cwd!()}"

      link = linked(named) ->
        "#{link}, a link, which writing the outputs would follow"

      true ->
        nil
    end
  end

  # By path, or by the file itself, so a link from one to the other is the same directory.
  defp same_directory?(sources, out) do
    Path.expand(sources) == Path.expand(out) or
      match?({{:ok, same}, {:ok, same}}, {identity(sources), identity(out)})
  end

  # A file system with no inodes, such as Windows', gives every file 0, which names nothing.
  defp identity(dir) do
    case File.stat(dir) do
      {:ok, %File.Stat{major_device: device, inode: inode}} when inode != 0 ->
        {:ok, {device, inode}}

      _no_inode ->
        :none
    end
  end

  defp render_all(sources, out, design, vocabulary, opts) do
    results =
      for source <- sources |> Path.join("*.svg") |> Path.wildcard() |> Enum.sort() do
        id = Path.basename(source, ".svg")
        opts = Keyword.put(opts, :source, Path.relative_to_cwd(Path.expand(source)))
        {id, EhosDiagrams.render(File.read!(source), id, design, vocabulary, opts)}
      end

    case for {id, {:error, reasons}} <- results,
             reason <- reasons,
             do: "#{sources}/#{id}.svg holds #{reason}" do
      [] -> unlinked(written(results, out), sources, out, design)
      refused -> {:error, refused}
    end
  end

  # An output that is a symbolic link would be written through it, and one that is a source's own
  # file, through a hard link, over the source. A licence is written only when it differs, so a
  # link to a file that holds the licence is never written through; a link to anything else is.
  defp unlinked(svgs, sources, out, design) do
    own =
      for source <- Path.wildcard(Path.join(sources, "*.svg")),
          {:ok, identity} <- [identity(source)],
          into: MapSet.new(),
          do: {:ok, identity}

    licences = licences(out, design)
    svg_links = for {path, _svg} <- svgs, link?(path) or identity(path) in own, do: path
    licence_links = for {path, text} <- licences, not own_licence?(path, text), do: path

    case Enum.sort(svg_links ++ licence_links) do
      [] -> {:ok, Map.merge(svgs, licences)}
      links -> {:error, Enum.map(links, &"#{&1}, a link, which writing the output would follow")}
    end
  end

  defp link?(path), do: match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))

  # The first part of a path below the current directory that is a link, the last part included.
  defp linked(path),
    do: path |> Path.split() |> Enum.scan(&Path.join(&2, &1)) |> Enum.find(&link?/1)

  # A licence that is not there, or is a file of its own, is written; any other is left alone
  # only when it is a file that already holds the licence, read only when its size says so, so a
  # link to a device or a pipe is never read.
  defp own_licence?(path, text) do
    case File.lstat(path) do
      {:error, :enoent} -> true
      {:ok, %File.Stat{type: :regular, links: 1}} -> true
      _link -> holds?(path, text)
    end
  end

  defp holds?(path, text) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size == byte_size(text) ->
        File.read(path) == {:ok, text}

      _other ->
        false
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

  @doc """
  The outputs in `out` that no source writes, sorted: left behind by a source removed. Only a file
  this package generated counts, by its first comment, so an SVG made by hand beside the outputs
  is never one.
  """
  @spec orphans(%{Path.t() => String.t()}, Path.t()) :: [Path.t()]
  def orphans(wanted, out) do
    written = MapSet.new(Map.keys(wanted), &Path.expand/1)

    for output <- out |> Path.join("*.svg") |> Path.wildcard() |> Enum.sort(),
        not MapSet.member?(written, Path.expand(output)),
        generated?(output),
        do: output
  end

  @generated ~s(<?xml version="1.0" encoding="UTF-8"?>\n<!-- Generated by )

  # Only a file of its own is read: a link to a pipe would block, and removing a link removes no
  # output.
  defp generated?(path) do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, @generated} <-
           File.open(path, [:read, :binary], &IO.binread(&1, byte_size(@generated))) do
      true
    else
      _other -> false
    end
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
