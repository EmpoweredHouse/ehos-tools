defmodule EhosDiagrams do
  @moduledoc """
  EHOS's diagrams (eh-os D-107, T-21): a source laid out by hand in SVG, checked and written again
  in `ehos_design`'s colours and fonts, light and dark.

  A source is data, never code. It is refused before it is parsed when it is not UTF-8, carries a
  DTD or holds a processing instruction, so it cannot pull a file from the machine that generates
  it. After parsing it is held to a list of elements, attributes, classes and local references, to
  the connector rules and to the budget. Its header names its title, its description, the glossary
  words its labels use, the names that are technical rather than words of the glossary, the verbs
  its connectors' labels use, and the concept each part stands for, by the part's id without the
  diagram's prefix (`-` for a part that is no concept):

      <!-- title: EHOS runs beside the client's applications -->
      <!-- desc: One sentence about what the diagram shows. -->
      <!-- words: application, governance plane, operator -->
      <!-- technical: Kubernetes, eh_os_contract -->
      <!-- verbs: submits, grants -->
      <!-- parts: client = how-a-command-runs, kubernetes = - -->
      <svg viewBox="0 0 1000 680" xmlns="http://www.w3.org/2000/svg"> … </svg>

  The words, the concepts and their badges are the host's: its `t:vocabulary/0`. A part's
  maturity is its concept's badge: a part whose badge has a treatment other than `:none` carries
  the badge's class (`m-planned`, `m-open`, …) and a tag naming the badge, and one whose badge is
  `:none` (eh-os's `built`) neither.

  The output is written here, with every value escaped, never copied from the source as text.
  `EhosDiagrams.Generator` renders a directory of sources, `EhosDiagrams.Pages` checks the pages
  that show them, and `mix ehos_diagrams.gen` does both for a host.
  """

  require Record

  Record.defrecordp(
    :element,
    :xmlElement,
    Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl")
  )

  Record.defrecordp(
    :attribute,
    :xmlAttribute,
    Record.extract(:xmlAttribute, from_lib: "xmerl/include/xmerl.hrl")
  )

  Record.defrecordp(
    :text,
    :xmlText,
    Record.extract(:xmlText, from_lib: "xmerl/include/xmerl.hrl")
  )

  @licences ~w(OFL-albert-sans.txt OFL-jetbrains-mono.txt)

  @elements ~w(svg g defs marker path line polyline polygon rect circle ellipse text tspan use)
  @attributes ~w(class id x y x1 y1 x2 y2 cx cy r rx ry width height d points transform viewBox
                 text-anchor marker-start marker-mid marker-end markerWidth markerHeight refX refY
                 orient href xlink:href xmlns xmlns:xlink)
  @references ~w(href xlink:href)
  @marker_references ~w(marker-start marker-mid marker-end)

  # The skin: each class, the tokens it takes, and the face its text is set in. A class not here,
  # nor a badge's of the vocabulary, is refused, so a part's look comes from its class alone.
  @skin %{
    "bg" => {"fill: var(--canvas)", nil},
    "mask" => {"fill: var(--canvas)", nil},
    "knock" => {"fill: var(--canvas)", nil},
    "zone" => {"fill: var(--surface-1); stroke: var(--border-soft); stroke-width: 0.8", nil},
    "zlabel" => {"fill: var(--text-tertiary); letter-spacing: 0.08em", {:mono, 500, 8}},
    "n-focal" => {"fill: var(--accent-soft); stroke: var(--accent-ink); stroke-width: 1.2", nil},
    "n-back" => {"fill: var(--surface-3); stroke: var(--text-primary); stroke-width: 1", nil},
    "n-store" =>
      {"fill: var(--border-faint); stroke: var(--text-secondary); stroke-width: 1", nil},
    "n-shared" => {"fill: var(--surface-1); stroke: var(--text-tertiary); stroke-width: 1", nil},
    "n-ext" => {"fill: var(--border-faint); stroke: var(--border-strong); stroke-width: 1", nil},
    "chip" => {"fill: var(--surface-3); stroke: var(--border-soft); stroke-width: 1", nil},
    "tag" => {"fill: none; stroke: var(--border-strong); stroke-width: 0.8", nil},
    "tag-focal" => {"fill: none; stroke: var(--accent-ink); stroke-width: 0.8", nil},
    "tagt" => {"fill: var(--text-tertiary); letter-spacing: 0.08em", {:mono, 500, 7}},
    "tagt-focal" => {"fill: var(--accent-ink); letter-spacing: 0.08em", {:mono, 500, 7}},
    "name" => {"fill: var(--text-primary); letter-spacing: -0.01em", {:sans, 500, 13}},
    "chipt" => {"fill: var(--text-primary)", {:sans, 400, 11}},
    "sub" => {"fill: var(--text-secondary)", {:mono, 400, 9.5}},
    "arr" => {"fill: none; stroke: var(--text-secondary); stroke-width: 1.2", nil},
    "uses" =>
      {"fill: none; stroke: var(--text-tertiary); stroke-width: 1; stroke-dasharray: 4 3", nil},
    "ring" => {"fill: none; stroke: var(--text-secondary); stroke-width: 1.2", nil},
    "head" => {"fill: var(--text-secondary)", nil},
    "lbl" => {"fill: var(--text-secondary); letter-spacing: 0.06em", {:mono, 500, 8.5}},
    "badge" => {"fill: var(--text-primary)", nil},
    "badget" => {"fill: var(--canvas)", {:mono, 500, 8}},
    "rule" => {"stroke: var(--border-soft); stroke-width: 0.8", nil},
    "keyt" => {"fill: var(--text-primary)", {:sans, 400, 11.5}},
    "legt" => {"fill: var(--text-secondary)", {:sans, 400, 10}},
    "eyes" => {"fill: var(--text-tertiary); letter-spacing: 0.08em", {:mono, 500, 8}},
    "legend" => {"", nil},
    "key" => {"", nil}
  }

  # A badge's outline (eh-os D-106, D-107). Maturity is a part's outline, never a connector's: a
  # connector's dashes mean optional or asynchronous. `:none` has no class at all.
  @treatments %{
    none: nil,
    solid: "",
    dashed: "stroke-dasharray: 5 4",
    dotted: "stroke-dasharray: 2 4",
    muted: "stroke: var(--text-muted)"
  }

  @parts ~w(n-focal n-back n-store n-shared n-ext)
  @connectors ~w(arr uses ring)
  @max_parts 9
  @max_connectors 12
  # Parts, chips and tags together, and masks and labels together: far above any diagram the budget
  # lets through, and low enough that matching each tag to its part, and each label to its mask,
  # stays cheap.
  @max_marks 200

  @faces %{
    {:sans, 400} => {"Albert Sans", "albert-sans-latin-400-normal.woff2"},
    {:sans, 500} => {"Albert Sans", "albert-sans-latin-500-normal.woff2"},
    {:mono, 400} => {"JetBrains Mono", "jetbrains-mono-latin-400-normal.woff2"},
    {:mono, 500} => {"JetBrains Mono", "jetbrains-mono-latin-500-normal.woff2"}
  }

  @tokens ~w(canvas surface-1 surface-3 text-primary text-secondary text-tertiary text-muted
             border-faint border-soft border-strong accent-ink accent-soft sans mono)

  @typedoc """
  What the skin is made of: the tokens of each theme, each face base64-encoded once, and the
  directory of the fonts and their licences.
  """
  @type design :: %{light: map(), dark: map(), faces: map(), fonts: Path.t()}

  @typedoc "How a part with a badge is outlined: `:none` shows no class and no tag."
  @type treatment :: :none | :solid | :dashed | :dotted | :muted

  @typedoc """
  What a source's words and parts are held to, given by the host:

    * `words`: the glossary words a header may list, in lower case;
    * `alone`: each word a person never reads alone, with the phrases it may appear in;
    * `concepts`: each concept a part may stand for, with its badge;
    * `badges`: each badge, a lowercase word, with its treatment. A host with no maturity gives
      no concepts and no badges, and names every part `-`.
  """
  @type vocabulary :: %{
          words: [String.t()],
          alone: [{String.t(), [String.t()]}],
          concepts: %{String.t() => String.t()},
          badges: [{String.t(), treatment()}]
        }

  @typedoc """
  Where an output says it comes from, in its first comment: "Generated by", the generator in
  backquotes, "from" the source, the record in brackets, and "Do not edit."

    * `:generator`: the command, `mix ehos_diagrams.gen` unless given;
    * `:source`: the source's path, `<id>.svg` unless given;
    * `:record`: the decision record it cites, none unless given.
  """
  @type option :: {:generator, String.t()} | {:source, String.t()} | {:record, String.t()}

  @doc "The fonts' licence files, which a host copies beside its outputs."
  @spec licences() :: [String.t()]
  def licences, do: @licences

  @doc "This package's `release.json` (eh-os D-91): what it is, with nothing it produces or accepts."
  @spec release(String.t()) :: map()
  def release(commit) when is_binary(commit) do
    %{
      "schema" => "ehos.release/v1",
      "component" => "ehos_diagrams",
      "version" => to_string(Application.spec(:ehos_diagrams, :vsn)),
      "commit" => commit,
      "produces" => [],
      "accepts" => [],
      "requires" => %{}
    }
  end

  @doc """
  The skin from `ehos_design` (eh-os D-72): its light and dark tokens from `colors_and_type.css`,
  and its fonts, from the `priv` directory given, or else the host's `ehos_design` (T-21). Raises
  when the host has no `ehos_design`.
  """
  @spec design(Path.t() | nil) :: design()
  def design(priv \\ nil) do
    priv = priv || ehos_design_priv()
    css = File.read!(Path.join(priv, "css/colors_and_type.css"))
    fonts = Path.join(priv, "static/ehos_design/fonts")

    %{
      light: tokens(css, :light),
      dark: tokens(css, :dark),
      faces: Map.new(@faces, fn {face, {_name, file}} -> {face, encode(fonts, file)} end),
      fonts: fonts
    }
  end

  defp ehos_design_priv do
    case :code.priv_dir(:ehos_design) do
      {:error, :bad_name} ->
        raise "ehos_diagrams reads ehos_design's tokens and fonts: add ehos_design to the " <>
                "project's dependencies (T-21)"

      priv ->
        to_string(priv)
    end
  end

  @doc """
  The tokens of one theme in `colors_and_type.css`, each `var(…)` resolved. Dark is the
  stylesheet's `:root`; light is that with its `prefers-color-scheme: light` block over it.
  """
  @spec tokens(String.t(), :light | :dark) :: %{String.t() => String.t()}
  def tokens(css, theme) do
    css = String.replace(css, ~r{/\*.*?\*/}s, "")
    [_, root] = Regex.run(~r/(?<!\S):root\s*\{([^}]*)\}/, css)
    dark = declarations(root)
    vars = if theme == :light, do: Map.merge(dark, light(css)), else: dark

    Map.new(@tokens, fn name -> {name, resolve(vars, name)} end)
  end

  defp light(css) do
    [_, light] =
      Regex.run(~r/@media\s*\(prefers-color-scheme:\s*light\)\s*\{\s*:root\s*\{([^}]*)\}/, css)

    declarations(light)
  end

  defp declarations(block) do
    ~r/--([\w-]+)\s*:\s*([^;]+);/
    |> Regex.scan(block, capture: :all_but_first)
    |> Map.new(fn [name, value] -> {name, String.trim(value)} end)
  end

  defp resolve(vars, name) do
    value = Map.fetch!(vars, name)

    Regex.replace(~r/var\(--([\w-]+)\)/, value, fn _, other -> resolve(vars, other) end)
  end

  @doc """
  The output for a source whose file is named `id`: `{:ok, svg}`, or `{:error, reasons}` naming
  each thing the source may not hold or breaks. `opts` say where the output comes from
  (`t:option/0`). Raises on a vocabulary or an option it cannot write, which is the caller's
  mistake, never the source's.

      iex> design = EhosDiagrams.design("../ehos_design/priv")
      iex> vocabulary = %{words: [], alone: [], concepts: %{}, badges: []}
      iex> source = \"""
      ...> <!-- title: Nothing -->
      ...> <!-- desc: An empty diagram. -->
      ...> <svg viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg"><script/></svg>
      ...> \"""
      iex> EhosDiagrams.render(source, "empty", design, vocabulary)
      {:error, ["the element <script>"]}
  """
  @spec render(String.t(), String.t(), design(), vocabulary(), [option()]) ::
          {:ok, String.t()} | {:error, [String.t()]}
  def render(source, id, design, vocabulary, opts \\ []) do
    skin = skin(vocabulary)

    with :ok <- named(id),
         :ok <- readable(source),
         {:ok, header, body} <- header(source),
         {:ok, svg} <- parse(body),
         :ok <- checked(svg, id, header, vocabulary, skin) do
      {:ok, write(svg, id, header, {design, skin, origin(id, opts)})}
    end
  end

  defp checked(svg, id, header, vocabulary, skin) do
    case problems(svg, id, header, vocabulary, skin) do
      [] -> :ok
      problems -> {:error, problems}
    end
  end

  # The skin with a class for each badge that has an outline.
  defp skin(%{badges: badges}) do
    Enum.each(badges, &badge!/1)

    for {badge, treatment} <- badges,
        treatment != :none,
        into: @skin,
        do: {"m-" <> badge, {@treatments[treatment], nil}}
  end

  # A badge names a class and is read back from a tag in capitals, so it is a lowercase word.
  defp badge!({badge, treatment}) do
    unless is_binary(badge) and badge =~ ~r/\A[a-z]+\z/ and Map.has_key?(@treatments, treatment) do
      raise ArgumentError,
            "the badge #{inspect(badge)} with the treatment #{inspect(treatment)}: a badge is a " <>
              "lowercase word, and its treatment one of #{inspect(Map.keys(@treatments))}"
    end
  end

  # The output's first comment, which must hold no "--".
  defp origin(id, opts) do
    generator = Keyword.get(opts, :generator, "mix ehos_diagrams.gen")
    source = Keyword.get(opts, :source, id <> ".svg")
    record = if opts[:record], do: " (#{opts[:record]})", else: ""
    origin = "`#{generator}` from #{source}#{record}"

    if String.contains?(origin, "--") or String.ends_with?(origin, "-"),
      do: raise(ArgumentError, "an origin an XML comment cannot hold: #{origin}"),
      else: origin
  end

  # The id names the file, scopes the stylesheet and prefixes every id inside, so it must be a
  # selector a browser reads as one id.
  defp named(id) do
    if id =~ ~r/\A[a-z][a-z0-9-]*\z/ and not String.contains?(id, "--"),
      do: :ok,
      else: {:error, ["a file name that is not lowercase letters, digits and single hyphens"]}
  end

  @max_bytes 256 * 1024

  # Refused before parsing, in this order: what a parser would act on rather than read. Each is a
  # test of the source and what it holds when the test is true.
  @unreadable [
    {&__MODULE__.too_large?/1, "more than #{@max_bytes} bytes"},
    {&__MODULE__.byte_order_mark?/1, "a byte-order mark"},
    {&__MODULE__.not_utf8?/1, "text that is not UTF-8"},
    {&__MODULE__.doctype?/1, "a DOCTYPE"},
    {&__MODULE__.entity?/1, "an ENTITY"},
    {&__MODULE__.processing_instruction?/1, "a processing instruction"},
    {&__MODULE__.other_encoding?/1, "an encoding other than UTF-8"}
  ]

  defp readable(source) do
    case Enum.find(@unreadable, fn {test, _reason} -> test.(source) end) do
      nil -> :ok
      {_test, reason} -> {:error, [reason]}
    end
  end

  @doc false
  def too_large?(source), do: byte_size(source) > @max_bytes
  @doc false
  def byte_order_mark?(source), do: String.starts_with?(source, <<0xEF, 0xBB, 0xBF>>)
  # UTF-16 of plain text is valid UTF-8, with a NUL beside every character.
  @doc false
  def not_utf8?(source), do: not String.valid?(source) or String.contains?(source, <<0>>)
  @doc false
  def doctype?(source), do: source =~ ~r/<!DOCTYPE/i
  @doc false
  def entity?(source), do: source =~ ~r/<!ENTITY/i
  @doc false
  # An XML declaration belongs at the start and nowhere else; anything else that opens with <? is a
  # processing instruction.
  def processing_instruction?(source),
    do: source |> String.replace(~r/\A<\?xml\s[^>?]*\?>/, "") |> String.contains?("<?")

  @doc false
  def other_encoding?(source), do: declared_encoding(source) not in [nil, "utf-8"]

  defp declared_encoding(source) do
    case Regex.run(~r/\A<\?xml\s[^>?]*encoding\s*=\s*["']([^"']+)["']/, source) do
      [_, encoding] -> String.downcase(encoding)
      nil -> nil
    end
  end

  defp header(source) do
    case String.split(source, ~r/<svg[\s>]/, parts: 2, include_captures: true) do
      [head, open, rest] -> fields(head, open <> rest)
      _no_svg -> {:error, ["no <svg> element"]}
    end
  end

  defp fields(head, body) do
    scanned = Regex.scan(~r/<!--\s*([a-z]+):\s*(.*?)\s*-->/s, head, capture: :all_but_first)
    fields = Map.new(scanned, fn [key, value] -> {key, value} end)
    twice = scanned |> Enum.map(&hd/1) |> duplicates()

    named =
      fields["parts"]
      |> list()
      |> Enum.map(&(&1 |> String.split("=") |> hd() |> String.trim()))

    missing = for key <- ~w(title desc), Map.get(fields, key, "") == "", do: key

    cond do
      missing != [] ->
        {:error, Enum.map(missing, &"no #{&1} in its header")}

      twice != [] ->
        {:error, Enum.map(twice, &"two #{&1} lines in its header")}

      (long = overlong(fields)) != [] ->
        {:error, long}

      duplicates(named) != [] ->
        {:error, Enum.map(duplicates(named), &"the part #{&1} twice in its header")}

      true ->
        {:ok,
         %{
           title: fields["title"],
           desc: fields["desc"],
           words: list(fields["words"]),
           technical: list(fields["technical"]),
           verbs: list(fields["verbs"]),
           parts: parts(fields["parts"])
         }, body}
    end
  end

  @max_entries 64
  @max_entry 120

  # The lists a label is matched against are short words and names; a longer one is refused
  # rather than compiled.
  defp overlong(fields) do
    for key <- ~w(words technical verbs parts),
        entries = list(fields[key]),
        problem <-
          if(length(entries) > @max_entries,
            do: ["more than #{@max_entries} entries in its header's #{key}"],
            else: []
          ) ++
            for(
              entry <- entries,
              String.length(entry) > @max_entry or byte_size(entry) > 4 * @max_entry,
              do: "an entry longer than #{@max_entry} characters in its header's #{key}"
            ),
        uniq: true,
        do: problem
  end

  defp duplicates(values),
    do: values |> Enum.frequencies() |> Enum.filter(&(elem(&1, 1) > 1)) |> Enum.map(&elem(&1, 0))

  defp list(nil), do: []

  defp list(value),
    do: value |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  # "id = concept, id = -" as a map; an entry without "=" is kept with a nil concept, so it is
  # reported rather than dropped.
  defp parts(value) do
    for entry <- list(value), into: %{} do
      case String.split(entry, "=", parts: 2) do
        [part, concept] -> {String.trim(part), String.trim(concept)}
        [part] -> {String.trim(part), nil}
      end
    end
  end

  defp parse(body) do
    {svg, _rest} = :xmerl_scan.string(:binary.bin_to_list(body), quiet: true, encoding: ~c"utf-8")
    {:ok, svg}
  catch
    :exit, reason -> {:error, ["XML that does not parse: #{inspect(reason, limit: 5)}"]}
  end

  # Everything the source breaks, in the order a reader would fix it.
  defp problems(svg, id, header, vocabulary, skin) do
    nodes = walk(svg, :root, false)
    budget = budget(nodes)

    Enum.concat([
      root(hd(nodes)),
      shape(nodes, skin),
      references(nodes),
      identifiers(nodes, id),
      connectors(nodes),
      budget,
      words(nodes, header, vocabulary),
      # The geometry of labels on masks and of tags in parts is read only within the budget, so a
      # large source is refused for its size rather than kept busy: each compares every label or
      # part with every mask, or every tag with every part.
      if(budget == [], do: masks(nodes) ++ maturity(nodes, id, header, vocabulary), else: [])
    ])
  end

  # Every element in document order, with its parent elements' classes and whether it or one of
  # them is transformed, which moves it out of the coordinates the checks read. Only text and
  # tspan elements carry their text.
  defp walk(element(name: name, attributes: attrs, content: content), ancestors, transformed) do
    name = Atom.to_string(name)
    attrs = Enum.map(attrs, &pair/1)
    inside = if ancestors == :root, do: [], else: ancestors

    node = %{
      name: name,
      attrs: attrs,
      text: if(name in ~w(text tspan), do: text_of(content), else: ""),
      inside: inside,
      root?: ancestors == :root,
      transformed?: transformed or List.keymember?(attrs, "transform", 0)
    }

    [
      node
      | Enum.flat_map(content, fn
          element() = child -> walk(child, classes(node) ++ inside, node.transformed?)
          _other -> []
        end)
    ]
  end

  defp pair(attribute(name: name, value: value)), do: {Atom.to_string(name), to_string(value)}

  defp text_of(content) do
    content
    |> Enum.flat_map(fn
      text(value: value) -> [List.to_string(value)]
      element(content: inner) -> [text_of(inner)]
      _other -> []
    end)
    |> Enum.join()
    |> String.trim()
  end

  defp attr(node, name), do: List.keyfind(node.attrs, name, 0, {name, nil}) |> elem(1)
  defp classes(node), do: (attr(node, "class") || "") |> String.split()
  defp number(node, name), do: node |> attr(name) |> to_float()

  # A number every browser reads, whole: "10", "-.5", "1e+3". Anything else is nil: "10px", "1."
  # (a trailing dot, which SVG 1.1 allows in a path but not in an attribute, and browsers may not
  # draw), and a number too large for a float.
  @number ~r/[-+]?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][-+]?\d+)?/

  defp to_float(nil), do: nil

  defp to_float(value) do
    value = String.trim(value)

    if Regex.match?(~r/^#{@number.source}$/, value) do
      # Float.parse/1 does not read ".5"; it gives :error for a number too large for a float.
      case value |> String.replace(~r/^([-+]?)\./, "\\g{1}0.") |> Float.parse() do
        {float, ""} -> float
        _too_large -> nil
      end
    end
  end

  defp numbers(text), do: @number |> Regex.scan(text) |> Enum.map(fn [n] -> to_float(n) end)

  defp shape(nodes, skin) do
    Enum.flat_map(nodes, fn node ->
      elements = if node.name in @elements, do: [], else: ["the element <#{node.name}>"]

      attributes =
        for {name, value} <- node.attrs, problem = attribute_problem(name, value), do: problem

      unknown =
        for class <- classes(node), not Map.has_key?(skin, class), do: "the class #{class}"

      elements ++ attributes ++ unknown ++ placement(node)
    end)
    |> Enum.uniq()
  end

  @namespaces %{
    "xmlns" => "http://www.w3.org/2000/svg",
    "xmlns:xlink" => "http://www.w3.org/1999/xlink"
  }

  # What is allowed only in one place: the namespaces on the root, a part's class on a <rect>, and
  # a transform on nothing the checks read coordinates from.
  defp placement(node) do
    namespaces =
      for {name, value} <- node.attrs,
          Map.has_key?(@namespaces, name),
          not node.root? or value != @namespaces[name],
          do: "the namespace #{name}=\"#{value}\""

    parts =
      if node.name != "rect" and Enum.any?(classes(node), &(&1 in @parts)),
        do: ["a part's class on <#{node.name}>, where a <rect> belongs"],
        else: []

    moved =
      if node.transformed? and
           Enum.any?(
             classes(node),
             &(&1 in (~w(arr uses mask lbl chip tagt tagt-focal) ++ @parts))
           ),
         do: [
           "a transform on a connector, a label, a mask, a part, a chip or a tag: #{describe(node)}"
         ],
         else: []

    namespaces ++ parts ++ moved
  end

  defp attribute_problem(name, value) do
    cond do
      name not in @attributes ->
        "the attribute #{name}"

      name in @references and not (value =~ ~r/^#[A-Za-z][\w-]*$/) ->
        "the reference #{value}"

      name in @marker_references and not (value =~ ~r/^url\(#[A-Za-z][\w-]*\)$/) ->
        "the reference #{value}"

      true ->
        nil
    end
  end

  # An id is prefixed with the diagram's, so two diagrams inlined in one page cannot share one.
  defp identifiers(nodes, id) do
    for node <- nodes,
        value = attr(node, "id"),
        not String.starts_with?(value, id <> "-"),
        do: "the id #{value}, which does not start with #{id}-"
  end

  defp connectors(nodes) do
    for node <- nodes,
        Enum.any?(classes(node), &(&1 in ~w(arr uses))),
        not orthogonal?(node),
        do: connector_problem(node)
  end

  defp connector_problem(%{name: "line"} = node) do
    if Enum.all?(~w(x1 y1 x2 y2), &(attr(node, &1) == nil or number(node, &1) != nil)),
      do: "a connector that is not orthogonal: #{describe(node)}",
      else: "a line whose ends are not numbers: #{describe(node)}"
  end

  defp connector_problem(node), do: "a connector that is not orthogonal: #{describe(node)}"

  # Each end is two numbers, a missing one 0 as SVG has it; one that is not a number is refused,
  # where two would otherwise compare equal.
  defp orthogonal?(%{name: "line"} = node) do
    case Enum.map(~w(x1 y1 x2 y2), &if(attr(node, &1), do: number(node, &1), else: 0.0)) do
      [x1, y1, x2, y2] when is_float(x1) and is_float(y1) and is_float(x2) and is_float(y2) ->
        x1 == x2 or y1 == y2

      _not_numbers ->
        false
    end
  end

  defp orthogonal?(%{name: name} = node) when name in ~w(polyline polygon) do
    text = attr(node, "points") || ""
    values = numbers(text)

    if only_separators_left?(text, @number) and values != [] and rem(length(values), 2) == 0 do
      points = values |> Enum.chunk_every(2) |> Enum.map(&List.to_tuple/1)
      points = if name == "polygon", do: points ++ Enum.take(points, 1), else: points
      points |> Enum.chunk_every(2, 1, :discard) |> Enum.all?(fn [a, b] -> axis?(a, b) end)
    else
      false
    end
  end

  defp orthogonal?(%{name: "path"} = node), do: path_orthogonal?(attr(node, "d") || "")
  defp orthogonal?(_node), do: false

  defp axis?({x1, y1}, {x2, y2}), do: x1 == x2 or y1 == y2

  # Every character is read as a token or is a separator, so nothing a browser would stop at, such
  # as "1." or "#", is skipped silently.
  defp only_separators_left?(text, tokens),
    do: text |> String.replace(tokens, " ") |> String.match?(~r/^[\s,]*$/)

  # Only moves, horizontal and vertical runs, and quadratic corners: a corner turns a run by a right
  # angle, its control point where the two runs would meet, at most 16 units each way.
  defp path_orthogonal?(d) do
    if only_separators_left?(d, ~r/[MmLlHhVvQqZz]|#{@number.source}/) do
      tokens = ~r/[MmLlHhVvQqZz]|#{@number.source}/ |> Regex.scan(d) |> List.flatten()
      segments(tokens, nil, {0.0, 0.0}, {0.0, 0.0}) == :ok
    else
      false
    end
  end

  defp segments([], _command, _point, _start), do: :ok

  defp segments([token | rest], _command, point, start) when token in ~w(M m L l H h V v Q q Z z),
    do: segments_after(token, rest, point, start)

  # Numbers after Z belong to no command.
  defp segments(_numbers, command, _point, _start) when command in ["Z", "z"], do: :error

  defp segments(numbers, command, point, start) when is_binary(command),
    do: segments_after(implicit(command), numbers, point, start)

  defp segments(_tokens, _command, _point, _start), do: :error

  defp implicit("M"), do: "L"
  defp implicit("m"), do: "l"
  defp implicit(command), do: command

  defp segments_after(command, rest, point, start) do
    relative? = command == String.downcase(command)

    arity =
      %{"m" => 2, "l" => 2, "h" => 1, "v" => 1, "q" => 4, "z" => 0}[String.downcase(command)]

    {numbers, rest} = Enum.split(rest, arity)

    with true <- length(numbers) == arity,
         {:ok, values} <- floats(numbers),
         {:ok, next} <- step(String.downcase(command), values, relative?, point, start) do
      start = if String.downcase(command) == "m", do: next, else: start
      segments(rest, command, next, start)
    else
      _broken -> :error
    end
  end

  defp floats(numbers) do
    values = Enum.map(numbers, &to_float/1)
    if Enum.all?(values), do: {:ok, values}, else: :error
  end

  defp step("m", [dx, dy], relative?, point, _start), do: {:ok, at(point, dx, dy, relative?)}

  defp step("l", [dx, dy], relative?, point, _start) do
    next = at(point, dx, dy, relative?)
    if axis?(point, next), do: {:ok, next}, else: :error
  end

  defp step("h", [v], relative?, {x, y}, _start),
    do: {:ok, {if(relative?, do: x + v, else: v), y}}

  defp step("v", [v], relative?, {x, y}, _start),
    do: {:ok, {x, if(relative?, do: y + v, else: v)}}

  defp step("q", [cx, cy, ex, ey], relative?, {x, y} = point, _start) do
    {cx, cy} = at(point, cx, cy, relative?)
    {ex, ey} = at(point, ex, ey, relative?)
    {dx, dy} = {abs(ex - x), abs(ey - y)}

    corner? =
      dx > 0 and dy > 0 and dx <= 16 and dy <= 16 and
        ({cx, cy} == {ex, y} or {cx, cy} == {x, ey})

    if corner?, do: {:ok, {ex, ey}}, else: :error
  end

  defp step("z", [], _relative?, point, start),
    do: if(axis?(point, start), do: {:ok, start}, else: :error)

  defp at({x, y}, dx, dy, true), do: {x + dx, y + dy}
  defp at(_point, x, y, false), do: {x, y}

  # Every connector label sits on a mask drawn before it, and no part is drawn over a mask.
  defp masks(nodes) do
    indexed = Enum.with_index(nodes)
    masks = for {node, i} <- indexed, "mask" in classes(node), do: {box(node), i}

    unplaced =
      for node <- nodes,
          "lbl" in classes(node),
          number(node, "x") == nil or number(node, "y") == nil,
          do: "a label with no x and y of its own: #{node.text}"

    unmasked =
      for {node, i} <- indexed,
          "lbl" in classes(node),
          number(node, "x") != nil and number(node, "y") != nil,
          not Enum.any?(masks, fn {box, j} -> j < i and inside?(box, node) end),
          do: "a label with no mask under it: #{node.text}"

    covered =
      for {node, i} <- indexed,
          part?(node),
          {box, j} <- masks,
          j < i and overlap?(box, box(node)),
          do: "a part drawn over a label's mask: #{describe(node)}"

    unplaced ++ unmasked ++ Enum.uniq(covered)
  end

  defp box(node),
    do:
      {number(node, "x") || 0.0, number(node, "y") || 0.0, number(node, "width") || 0.0,
       number(node, "height") || 0.0}

  defp inside?({x, y, w, h}, node) do
    {tx, ty} = {number(node, "x"), number(node, "y")}
    tx >= x and tx <= x + w and ty >= y and ty <= y + h
  end

  defp overlap?({x1, y1, w1, h1}, {x2, y2, w2, h2}),
    do: x1 < x2 + w2 and x2 < x1 + w1 and y1 < y2 + h2 and y2 < y1 + h1

  defp part?(node), do: node.name == "rect" and Enum.any?(classes(node), &(&1 in @parts))
  defp in_legend?(node), do: Enum.any?(node.inside, &(&1 in ~w(legend key)))

  # The root is an <svg> with a viewBox of four numbers, which the output's size comes from.
  defp root(%{name: "svg"} = node) do
    if view_box(attr(node, "viewBox")), do: [], else: ["no viewBox of four numbers on its <svg>"]
  end

  defp root(node), do: ["a root <#{node.name}> where <svg> belongs"]

  defp view_box(nil), do: nil

  defp view_box(value) do
    numbers = String.split(value, ~r/[\s,]+/, trim: true)

    with [_x, _y, width, height] <- numbers,
         values = Enum.map(numbers, &to_float/1),
         true <- Enum.all?(values),
         true <- to_float(width) > 0 and to_float(height) > 0 do
      numbers
    else
      _not_four_numbers -> nil
    end
  end

  # Every local reference points at an id the source holds.
  defp references(nodes) do
    ids = for node <- nodes, id = attr(node, "id"), into: MapSet.new(), do: id

    for node <- nodes,
        {name, value} <- node.attrs,
        name in @references or name in @marker_references,
        [_, id] <- [Regex.run(~r/^(?:url\()?#([A-Za-z][\w-]*)\)?$/, value)],
        not MapSet.member?(ids, id),
        do: "a reference to #{value}, which no element holds"
  end

  defp budget(nodes) do
    drawn = Enum.reject(nodes, &in_legend?/1)
    parts = Enum.count(drawn, &part?/1)
    connectors = Enum.count(drawn, fn node -> Enum.any?(classes(node), &(&1 in @connectors)) end)

    marks = Enum.count(drawn, &(holder?(&1) or tag?(&1)))
    masked = Enum.count(nodes, fn node -> Enum.any?(classes(node), &(&1 in ~w(mask lbl))) end)

    Enum.concat([
      if(parts > @max_parts, do: ["#{parts} parts, more than #{@max_parts}"], else: []),
      if(marks > @max_marks,
        do: ["#{marks} parts, chips and tags, more than #{@max_marks}"],
        else: []
      ),
      if(masked > @max_marks,
        do: ["#{masked} masks and labels, more than #{@max_marks}"],
        else: []
      ),
      if(connectors > @max_connectors,
        do: ["#{connectors} connectors, more than #{@max_connectors}"],
        else: []
      )
    ])
  end

  @label_kinds %{"name" => "name", "chipt" => "chip", "lbl" => "connector label"}
  @label_rules %{
    "name" => "neither a word of its header nor technical",
    "chipt" => "neither a word of its header nor technical",
    "lbl" => "neither a word of its header, technical nor one of its verbs"
  }

  # A part's name, a chip and a connector's label is a word of the header, which the glossary
  # holds, a technical name or, for a connector's label, one of the header's verbs. No text shows
  # a word the glossary says a person never reads alone, such as "binding" outside "role binding".
  defp words(nodes, header, vocabulary) do
    unknown = for word <- header.words, String.downcase(word) not in vocabulary.words, do: word

    technical = MapSet.new(header.technical, &String.downcase/1)
    words = Enum.map(header.words, &whole/1)
    verbs = Enum.map(header.verbs, &whole/1)

    labels =
      for node <- nodes,
          class <- Enum.filter(classes(node), &(&1 in ~w(name chipt lbl))),
          not MapSet.member?(technical, String.downcase(node.text)),
          not Enum.any?(
            words ++ if(class == "lbl", do: verbs, else: []),
            &Regex.match?(&1, node.text)
          ),
          do: "the #{@label_kinds[class]} #{node.text}, which is #{@label_rules[class]}"

    rules =
      for {word, phrases} <- vocabulary.alone,
          do: {word, whole(word), Enum.map(phrases, &whole/1)}

    alone =
      for text <- [header.title, header.desc | Enum.map(nodes, & &1.text)],
          {word, pattern, phrases} <- rules,
          alone?(text, pattern, phrases),
          do: "\"#{word}\" alone in: #{text}"

    Enum.map(unknown, &"the word #{&1}, which is not in the glossary") ++
      labels ++ Enum.uniq(alone)
  end

  # A word or phrase, whole, in any case, perhaps plural. The header bounds the length of its own
  # entries; the glossary's words and phrases are this repository's.
  defp whole(word), do: Regex.compile!("(?<!\\w)#{Regex.escape(word)}s?(?!\\w)", "iu")

  # An allowed phrase counts only whole, so "xrole binding" still shows "binding" alone.
  defp alone?(text, pattern, phrases),
    do:
      phrases
      |> Enum.reduce(text, &Regex.replace(&1, &2, " "))
      |> then(&Regex.match?(pattern, &1))

  # Each part and chip outside the legend has an id its header names, with the concept it stands
  # for or "-"; its outline is the concept's badge, and a tag inside it names a badge only when it
  # has an outline (eh-os D-106, D-107). A tag is placed by its own x and y, inside a part or a chip, and
  # the legend and the key are one each and hold only swatches, so none is a way around this.
  defp maturity(nodes, id, header, vocabulary) do
    drawn = Enum.reject(nodes, &in_legend?/1)
    holders = Enum.filter(drawn, &holder?/1)
    tags = Enum.filter(drawn, &tag?/1)

    named = for holder <- holders, do: {holder, part_name(holder, id)}

    unknown =
      for {holder, name} <- named,
          not Map.has_key?(header.parts, name),
          do: "a part or chip its header's parts do not name: #{describe(holder)}"

    stale =
      for {name, _concept} <- header.parts,
          not Enum.any?(named, fn {_holder, drawn} -> drawn == name end),
          do: "the part #{name} in its header, which it does not draw"

    twice =
      for {name, count} <- named |> Enum.map(&elem(&1, 1)) |> Enum.frequencies(),
          name != nil and count > 1,
          do: "the part #{name} drawn #{count} times"

    held = holders_of(holders, tags)

    wrong =
      for {holder, name} <- named,
          Map.has_key?(header.parts, name),
          tags = for({tag, ^holder} <- held, do: String.upcase(tag.text)),
          problem <- part_maturity(holder, name, header.parts[name], vocabulary, tags),
          do: problem

    unknown ++
      stale ++
      twice ++
      wrong ++
      over_parts(nodes, holders) ++
      loose_tags(nodes, tags, held) ++ legends(nodes) ++ marks(nodes)
  end

  # Each placed tag with the smallest part or chip around its anchor, or nil: one pass over the
  # tags, each box read once.
  defp holders_of(holders, tags) do
    boxed = for holder <- holders, do: {holder, box(holder)}

    for tag <- tags, x = number(tag, "x"), y = number(tag, "y"), x != nil and y != nil do
      holder =
        boxed
        |> Enum.filter(fn {_holder, {bx, by, w, h}} ->
          x >= bx and x <= bx + w and y >= by and y <= by + h
        end)
        |> Enum.min_by(fn {_holder, {_x, _y, w, h}} -> w * h end, fn -> {nil, nil} end)
        |> elem(0)

      {tag, holder}
    end
  end

  # A tag in the legend shows what a tag looks like; drawn over a part, it would be that part's.
  defp over_parts(nodes, holders) do
    legend_tags = Enum.filter(nodes, &(in_legend?(&1) and tag?(&1)))

    for {tag, holder} <- holders_of(holders, legend_tags),
        holder != nil,
        do: "a tag of the legend or the key drawn over a part or chip: #{tag.text}"
  end

  defp holder?(node), do: part?(node) or (node.name == "rect" and "chip" in classes(node))
  defp tag?(node), do: Enum.any?(classes(node), &(&1 in ~w(tagt tagt-focal)))

  defp loose_tags(nodes, tags, held) do
    positioned =
      for node <- nodes,
          node.name == "tspan",
          Enum.any?(node.inside, &(&1 in ~w(tagt tagt-focal))),
          attr(node, "x") != nil or attr(node, "y") != nil,
          do: "a tag placed by a <tspan>: #{node.text}"

    unplaced =
      for tag <- tags,
          number(tag, "x") == nil or number(tag, "y") == nil,
          do: "a tag with no x and y of its own: #{tag.text}"

    outside = for {tag, nil} <- held, do: "a tag in no part or chip: #{tag.text}"

    positioned ++ unplaced ++ outside
  end

  @swatch 20

  defp legends(nodes) do
    groups =
      for kind <- ~w(legend key),
          count = Enum.count(nodes, &(&1.name == "g" and kind in classes(&1))),
          count > 1,
          do: "#{count} groups of class #{kind}, where one belongs"

    large =
      for node <- nodes,
          in_legend?(node),
          holder?(node),
          {_x, _y, w, h} = box(node),
          w > @swatch or h > @swatch,
          do: "a part in the legend or the key larger than a swatch: #{describe(node)}"

    # A legend's class on anything but a group would hide a badge from the checks above.
    misplaced =
      for node <- nodes,
          node.name != "g",
          Enum.any?(classes(node), &(&1 in ~w(legend key))),
          do: "the class legend or key on <#{node.name}>, where a <g> belongs"

    groups ++ large ++ misplaced
  end

  # A part or chip whose size is not two numbers, or a <use> that draws one or a tag again.
  defp marks(nodes) do
    unsized =
      for node <- nodes,
          holder?(node),
          number(node, "width") == nil or number(node, "height") == nil,
          do: "a part or chip whose width and height are not numbers: #{describe(node)}"

    marked =
      for node <- nodes,
          holder?(node) or tag?(node),
          id = attr(node, "id"),
          id != nil,
          into: MapSet.new(),
          do: id

    redrawn =
      for node <- nodes,
          node.name == "use",
          target = attr(node, "href") || attr(node, "xlink:href"),
          is_binary(target),
          MapSet.member?(marked, String.trim_leading(target, "#")),
          do: "a <use> that draws a part, a chip or a tag again: #{describe(node)}"

    unsized ++ redrawn
  end

  defp part_name(part, id) do
    case attr(part, "id") do
      nil -> nil
      value -> String.replace_prefix(value, id <> "-", "")
    end
  end

  defp part_maturity(part, name, concept, vocabulary, tags) do
    shown = Enum.filter(classes(part), &String.starts_with?(&1, "m-"))

    words = tags |> Enum.flat_map(&String.split(&1, ~r/[^A-Z]+/, trim: true)) |> MapSet.new()

    tagged =
      for {badge, _treatment} <- vocabulary.badges,
          word = String.upcase(badge),
          word in words,
          do: word

    badge = vocabulary.concepts[concept]
    treatment = List.keyfind(vocabulary.badges, badge, 0, {badge, nil}) |> elem(1)

    shows(name, concept, {badge, treatment}, shown, tagged)
  end

  defp shows(name, nil, _badge, _shown, _tagged),
    do: ["the part #{name} in its header, with no concept after \"=\""]

  defp shows(_name, "-", _badge, [], []), do: []

  defp shows(name, "-", _badge, _shown, _tagged),
    do: ["the part #{name}, which stands for no concept and shows a badge"]

  # A concept the vocabulary does not hold, or whose badge it does not know.
  defp shows(name, concept, {_badge, nil}, _shown, _tagged),
    do: ["the part #{name}, whose concept #{concept} its vocabulary does not hold"]

  defp shows(name, concept, {badge, :none}, shown, tagged) do
    cond do
      shown != [] ->
        ["the part #{name}, whose outline is not #{badge}, the badge of #{concept}"]

      tagged != [] ->
        ["the part #{name}, which is #{badge} and tagged #{Enum.join(tagged, ", ")}"]

      true ->
        []
    end
  end

  defp shows(name, concept, {badge, _treatment}, shown, tagged) do
    word = String.upcase(badge)

    cond do
      shown != ["m-" <> badge] ->
        ["the part #{name}, whose outline is not #{badge}, the badge of #{concept}"]

      tagged != [word] ->
        ["the part #{name}, whose tag does not name #{word}, the badge of #{concept}"]

      true ->
        []
    end
  end

  defp describe(node),
    do: "<#{node.name} #{Enum.map_join(node.attrs, " ", fn {k, v} -> "#{k}=\"#{v}\"" end)}>"

  defp write(element(attributes: attrs, content: content), id, header, {design, skin, origin}) do
    view_box = attrs |> Enum.map(&pair/1) |> List.keyfind("viewBox", 0) |> elem(1)
    [_, _, width, height] = String.split(view_box, ~r/[\s,]+/, trim: true)
    used = used_classes(content)

    xlink =
      if IO.iodata_to_binary(Enum.map(content, &serialize(&1, 0))) =~ " xlink:href=",
        do: [{"xmlns:xlink", @namespaces["xmlns:xlink"]}],
        else: []

    root =
      [{"xmlns", @namespaces["xmlns"]}] ++
        xlink ++
        [
          {"id", id},
          {"viewBox", view_box},
          {"width", width},
          {"height", height},
          {"role", "img"},
          {"aria-labelledby", "#{id}-title #{id}-desc"}
        ]

    IO.iodata_to_binary([
      ~s(<?xml version="1.0" encoding="UTF-8"?>\n),
      "<!-- Generated by #{origin}. Do not edit. ",
      "The fonts are Albert Sans and JetBrains Mono, under the SIL Open Font License 1.1: ",
      "see OFL-albert-sans.txt and OFL-jetbrains-mono.txt beside this file. -->\n",
      "<svg",
      attributes(root),
      ">\n",
      ~s(  <title id="#{id}-title">#{escape(header.title)}</title>\n),
      ~s(  <desc id="#{id}-desc">#{escape(header.desc)}</desc>\n),
      "  <defs><style>",
      escape_text(stylesheet(id, used, design, skin)),
      "</style></defs>\n",
      Enum.map(content, &serialize(&1, 1)),
      "</svg>\n"
    ])
  end

  defp used_classes(content) do
    content
    |> Enum.flat_map(fn
      element() = child -> walk(child, [], false)
      _other -> []
    end)
    |> Enum.flat_map(&classes/1)
    |> MapSet.new()
  end

  defp stylesheet(id, used, design, skin) do
    scope = "#" <> id
    classes = used |> Enum.sort() |> Enum.filter(&Map.has_key?(skin, &1))

    faces =
      classes
      |> Enum.flat_map(fn class ->
        case skin[class] do
          {_rule, {family, weight, _size}} -> [{family, weight}]
          _no_text -> []
        end
      end)
      |> Enum.uniq()
      |> Enum.sort()

    [
      "#{scope}{#{variables(design.light)}}",
      "@media (prefers-color-scheme: dark){#{scope}{#{variables(design.dark)}}}",
      Enum.map(faces, &font_face(&1, design.faces)),
      Enum.map(classes, &rule(scope, &1, skin[&1]))
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp variables(tokens),
    do: tokens |> Enum.sort() |> Enum.map_join(";", fn {name, value} -> "--#{name}:#{value}" end)

  # Reads a font this module names, from ehos_design's priv directory.
  defp encode(fonts, file), do: fonts |> Path.join(file) |> File.read!() |> Base.encode64()

  defp font_face({family, weight}, faces) do
    {name, _file} = @faces[{family, weight}]
    data = Map.fetch!(faces, {family, weight})

    "@font-face{font-family:\"#{name}\";font-weight:#{weight};font-style:normal;" <>
      "src:url(data:font/woff2;base64,#{data}) format(\"woff2\")}"
  end

  defp rule(scope, class, {declarations, font}) do
    body = [declarations, font(font)] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("; ")
    "#{scope} .#{class}{#{body}}"
  end

  defp font({family, weight, size}), do: "font: #{weight} #{size}px var(--#{family})"
  defp font(nil), do: nil

  defp serialize(element(name: name, attributes: attrs, content: content), depth) do
    indent = String.duplicate("  ", depth)
    open = [indent, "<", Atom.to_string(name), attributes(Enum.map(attrs, &pair/1))]
    children = for element() = child <- content, do: child
    text = text_of(content)

    close = ["</", Atom.to_string(name), ">\n"]

    cond do
      children == [] and text == "" ->
        [open, "/>\n"]

      children == [] ->
        [open, ">", escape(text), close]

      # Text beside elements, as in a <text> with a <tspan>, keeps its order on one line.
      Enum.any?(content, &text_node?/1) ->
        [open, ">", Enum.map(content, &inline/1), close]

      true ->
        [open, ">\n", Enum.map(children, &serialize(&1, depth + 1)), indent, close]
    end
  end

  defp serialize(_text_or_comment, _depth), do: []

  defp text_node?(text(value: value)), do: String.trim(List.to_string(value)) != ""
  defp text_node?(_other), do: false

  defp inline(element(name: name, attributes: attrs, content: content)) do
    tag = Atom.to_string(name)

    [
      "<",
      tag,
      attributes(Enum.map(attrs, &pair/1)),
      ">",
      Enum.map(content, &inline/1),
      "</",
      tag,
      ">"
    ]
  end

  defp inline(text(value: value)), do: escape(List.to_string(value))
  defp inline(_comment), do: []

  defp attributes(pairs),
    do: Enum.map(pairs, fn {name, value} -> [" ", name, "=\"", escape(value), "\""] end)

  # A stylesheet is text: its quotes stay, so it reads the same inlined into an HTML page.
  defp escape_text(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  @doc "Text and attribute values escaped for XML."
  @spec escape(String.t()) :: String.t()
  def escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
