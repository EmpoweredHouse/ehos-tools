defmodule Ehosctl.ServiceYaml.Reader do
  @moduledoc """
  An `ehos.yaml` read into JSON's data model, as EHOS reads one before its schema sees it (eh-os
  D-51), refusing what JSON cannot say: an anchor or an alias, a tag, a directive, a duplicate
  key, a key that is not a string, a second document, a number JSON cannot hold, a NUL, bytes that
  are not UTF-8. So is what only makes a parser work: nesting deeper than 16 levels, more than 256
  of `[` and `{`, a list of more than 256 entries, a file the parser works on for more than 20
  million reductions, which is about a second of work on an idle machine. YAML 1.2's core schema
  resolves plain scalars, so `yes` and `on` are strings.

  It is eh-os's `Ehos.Applications.EhosYaml.Yaml`, with the same bounds and the same words, so a
  file `ehosctl` reads is a file EHOS reads, and one it refuses EHOS refuses. One bound differs
  until eh-os takes the same change: eh-os stops a parse after a second of real time, where this
  module counts the parser's work.
  """

  # yamerl reads twice: its parser's tokens show anchors, aliases, tags and directives, which its
  # tree no longer does, and its detailed tree keeps every key of a mapping with its line.

  @typedoc "Where a value is: its keys and indexes from the top. The document is `[]`."
  @type path :: [String.t() | non_neg_integer()]

  @typedoc "One reason a file is refused: where, the line when known, and why."
  @type error :: %{path: path(), line: pos_integer() | nil, message: String.t()}

  @typedoc "The line each value is on, by its path: for a mapping's value, the line of its key."
  @type lines :: %{path() => pos_integer()}

  @construction [:detailed_constr, {:schema, :core}, {:keep_duplicate_keys, true}]
  # yamerl's work grows with the square of how deep a file nests, so a deeper one is refused as
  # its parser reaches the limit, before anything is built.
  @max_depth 16
  # yamerl holds back the tokens of a flow collection until it has read the whole of it, so how
  # many there may be is bounded before it reads anything.
  @max_flow 256
  @max_items 256
  # Whatever else makes yamerl work, it may do this much work and use this much memory, in a
  # process of its own, and no more. The work is counted in reductions, not time, so a busy
  # machine refuses no file an idle one reads. A 50 KB ehos.yaml takes yamerl about 1 million
  # reductions, and the budget is about a second of work on an idle machine. The parse is looked
  # at every 50 ms, and a parse that ends counts its own work before it sends its result, so one
  # that passed the budget between two looks is refused too.
  @max_reductions 20_000_000
  @look_ms 50
  @max_heap_words 4_000_000
  @directives [:yamerl_yaml_directive, :yamerl_tag_directive, :yamerl_reserved_directive]
  @only_json "ehos.yaml holds only what JSON can"

  @doc """
  The document in `text`, with the line of each value, or every reason it is refused.
  """
  @spec decode(binary()) :: {:ok, term(), lines()} | {:error, [error()]}
  def decode(text) when is_binary(text) do
    with :ok <- readable(text), do: within_budget(fn -> parse(text) end)
  end

  defp parse(text) do
    with :ok <- plain(text),
         {:ok, root} <- construct(text) do
      data(root)
    end
  end

  # The parse runs in a process killed when it passes the budget. Whatever yamerl raises there, as
  # it does on a file that starts with `:`, is a file it cannot read.
  defp within_budget(parse) do
    caller = self()
    tag = make_ref()

    {pid, ref} =
      :erlang.spawn_opt(
        fn -> send(caller, {tag, counted(guarded(parse))}) end,
        [:monitor, max_heap_size: %{size: @max_heap_words, kill: true, error_logger: false}]
      )

    awaited(pid, ref, tag)
  end

  defp awaited(pid, ref, tag) do
    receive do
      {^tag, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, _killed} ->
        refuse(nil, over_budget())
    after
      @look_ms -> looked(pid, ref, tag, Process.info(pid, :reductions))
    end
  end

  defp looked(pid, ref, tag, {:reductions, reductions}) when reductions > @max_reductions,
    do: stopped(pid, ref, tag)

  # A process that has ended has sent its result or its `:DOWN`, which the next wait receives.
  defp looked(pid, ref, tag, _working_or_ended), do: awaited(pid, ref, tag)

  defp guarded(parse) do
    parse.()
  rescue
    _exception -> refuse(nil, "the file is not YAML that EHOS can read")
  end

  defp counted(result), do: counted(result, Process.info(self(), :reductions))

  defp counted(_result, {:reductions, reductions}) when reductions > @max_reductions,
    do: refuse(nil, over_budget())

  defp counted(result, _within), do: result

  # A result the process sent before it died reaches the caller before its `:DOWN`, so once that
  # has come, no result is left behind in the caller's mailbox.
  defp stopped(pid, ref, tag) do
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _killed} -> :ok
    end

    receive do
      {^tag, _result} -> :ok
    after
      0 -> :ok
    end

    refuse(nil, over_budget())
  end

  defp over_budget,
    do: "the file takes more to parse than an ehos.yaml ever does; it is not read"

  # yamerl stops at a raw NUL with a function clause error, and reads bytes that are not UTF-8 as
  # Latin-1; both are refused before it reads anything.
  defp readable(text) do
    cond do
      not String.valid?(text) ->
        refuse(nil, "the file is not UTF-8 text")

      String.contains?(text, <<0>>) ->
        refuse(nil, nul())

      length(:binary.matches(text, ["[", "{"])) > @max_flow ->
        refuse(
          nil,
          "the file holds more than #{@max_flow} of [ and {, far more than ehos.yaml needs"
        )

      true ->
        :ok
    end
  end

  defp plain(text) do
    _ = :yamerl_parser.string(text, [{:token_fun, token_fun(0, 0)}])
    :ok
  catch
    {__MODULE__, error} -> {:error, [error]}
    {:yamerl_exception, errors} -> {:error, Enum.map(errors, &parsing_error/1)}
  end

  # The token function carries how deep the parser is and how many documents it has begun, so a
  # second document, or a collection past the limit, is refused as soon as the parser reaches it.
  defp token_fun(depth, documents), do: &{:ok, next(&1, depth, documents)}

  defp next({:yamerl_doc_start, line, _column, _version, _tags}, _depth, 1),
    do: throw_refusal(line, "the file holds more than one YAML document")

  defp next({:yamerl_doc_start, _line, _column, _version, _tags}, depth, documents),
    do: token_fun(depth, documents + 1)

  defp next({:yamerl_collection_start, line, _column, _tag, _style, _kind}, @max_depth, _docs),
    do: throw_refusal(line, "nests deeper than #{@max_depth} levels")

  defp next({:yamerl_collection_start, _line, _column, tag, _style, _kind}, depth, documents) do
    untagged(tag)
    token_fun(depth + 1, documents)
  end

  defp next({:yamerl_collection_end, _line, _column, _style, _kind}, depth, documents),
    do: token_fun(depth - 1, documents)

  defp next(token, depth, documents) do
    plain_token(token)
    token_fun(depth, documents)
  end

  defp plain_token({:yamerl_anchor, line, _column, name}),
    do: throw_refusal(line, "an anchor (&#{name}) is refused: #{@only_json}")

  defp plain_token({:yamerl_alias, line, _column, name}),
    do: throw_refusal(line, "an alias (*#{name}) is refused: #{@only_json}")

  defp plain_token(token) when elem(token, 0) in @directives,
    do: throw_refusal(elem(token, 1), "a directive is refused: ehos.yaml is YAML 1.2 as it is")

  defp plain_token({:yamerl_scalar, _line, _column, tag, _style, _substyle, _text}),
    do: untagged(tag)

  defp plain_token(_token), do: :ok

  # A node written without a tag has a non-specific one: `?` when plain, `!` when quoted.
  defp untagged({:yamerl_tag, _line, _column, {:non_specific, _}}), do: :ok

  defp untagged({:yamerl_tag, line, _column, uri}),
    do: throw_refusal(line, "a tag (#{uri}) is refused: #{@only_json}")

  # yamerl calls the token function for each token as it parses; throwing is how it stops.
  @spec throw_refusal(term(), String.t()) :: no_return()
  defp throw_refusal(line, message), do: throw({__MODULE__, error([], position(line), message)})

  defp parsing_error({:yamerl_parsing_error, _type, text, line, _column, _name, _token, _extra}),
    do: error([], position(line), "the file is not YAML: #{text}")

  defp construct(text) do
    case :yamerl_constr.string(text, @construction) do
      [] -> refuse(nil, "the file holds no YAML document")
      # A second document has been refused by the token function.
      [{:yamerl_doc, root}] -> {:ok, root}
    end
  catch
    {:yamerl_exception, errors} -> {:error, Enum.map(errors, &parsing_error/1)}
  end

  defp data(root) do
    {data, {lines, errors}} = node(root, [], at({%{}, []}, [], line(root)))

    case errors do
      [] -> {:ok, data, lines}
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  defp node({:yamerl_map, _module, _tag, _position, pairs}, path, acc) do
    {entries, _seen, acc} =
      Enum.reduce(pairs, {[], %{}, acc}, fn {key, value}, state ->
        pair(key, value, path, state)
      end)

    {Map.new(entries), acc}
  end

  defp node({:yamerl_seq, _module, _tag, _position, _items, count} = seq, path, {lines, _} = acc)
       when count > @max_items do
    # The line of the list's key, where there is one, as for every other reason.
    {[],
     add(
       acc,
       error(path, Map.get(lines, path, line(seq)), "lists more than #{@max_items} entries")
     )}
  end

  defp node({:yamerl_seq, _module, _tag, _position, items, _count}, path, acc) do
    items
    |> Enum.with_index()
    |> Enum.map_reduce(acc, fn {item, index}, acc ->
      node(item, path ++ [index], at(acc, path ++ [index], line(item)))
    end)
  end

  defp node({:yamerl_str, _module, _tag, _position, chars} = str, path, acc) do
    string = List.to_string(chars)

    if String.contains?(string, <<0>>),
      do: {string, add(acc, error(path, line(str), nul()))},
      else: {string, acc}
  end

  defp node({:yamerl_null, _module, _tag, _position}, _path, acc), do: {nil, acc}

  defp node({kind, _module, _tag, _position, value}, _path, acc)
       when (kind == :yamerl_int and is_integer(value)) or
              (kind == :yamerl_float and is_float(value)) or
              (kind == :yamerl_bool and is_boolean(value)),
       do: {value, acc}

  # `.inf` and `.nan` are floats to YAML and nothing to JSON.
  defp node(other, path, acc),
    do: {nil, add(acc, error(path, line(other), "is a number JSON cannot hold"))}

  defp pair({:yamerl_str, _module, _tag, _position, chars} = key, value, path, state) do
    named(List.to_string(chars), key, value, path, state)
  end

  defp pair(key, _value, path, {entries, seen, acc}),
    do: {entries, seen, add(acc, error(path, line(key), "has a key that is not a string"))}

  defp named(name, key, value, path, {entries, seen, acc}) do
    child = path ++ [name]

    cond do
      # A reason's path quotes its key, and is shown where a NUL cannot be kept.
      String.contains?(name, <<0>>) ->
        {entries, seen, add(acc, error(path, line(key), "has a key that #{nul()}"))}

      Map.has_key?(seen, name) ->
        message = "is given twice in one mapping; the first is on line #{seen[name]}"
        {entries, seen, add(acc, error(child, line(key), message))}

      true ->
        {data, acc} = node(value, child, at(acc, child, line(key)))
        {[{name, data} | entries], Map.put(seen, name, line(key)), acc}
    end
  end

  defp at(acc, _path, nil), do: acc
  defp at({lines, errors}, path, line), do: {Map.put(lines, path, line), errors}

  defp add({lines, errors}, error), do: {lines, [error | errors]}

  defp line(node) do
    case elem(node, 3) do
      position when is_list(position) -> position(Keyword.get(position, :line))
      _other -> nil
    end
  end

  defp position(line) when is_integer(line) and line > 0, do: line
  defp position(_line), do: nil

  defp nul, do: "holds a NUL character, which EHOS cannot store"

  defp refuse(line, message), do: {:error, [error([], line, message)]}

  defp error(path, line, message), do: %{path: path, line: line, message: message}
end
