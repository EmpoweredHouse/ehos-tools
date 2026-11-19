defmodule Ehosctl.Notice do
  @moduledoc """
  After a command, at most once a day, a line on stderr when a newer `ehosctl` is released, or
  when the installation the command used no longer accepts this one (eh-os D-91, ehos-tools#97).
  On 9 October 2026 two applications were generated with 0.1.1 on the morning 0.2.0 came out,
  and nothing said so.

  It never gets in the way:

    * it stays silent in CI (`CI` set to anything), under `--json`, when stderr is not a
      terminal, when `EHOSCTL_NO_UPDATE_NOTICE` is set, and after `versions` and `changelog`,
      which say it themselves;
    * it runs after the command has printed, and never changes its output or exit code: any
      error is swallowed;
    * what it knows is kept in `notice.json` in the user's cache directory
      (`:filename.basedir(:user_cache, "ehosctl")`), refreshed at most once a day for each
      source, within two seconds, and written whole or not at all (`Ehosctl.PrivateFile`).
      When it cannot be written, nothing is asked or said. The file is read without trusting
      it: a part that is not of its shape is dropped and asked again;
    * GitHub is asked for `ehosctl`'s newest release, and the installation for `GET /api/v1` only
      with the credential the command left cached: the notice never renews a sign-in.

  The cache:

  ```json
  {"version": 1,
   "noticed_at": "2026-10-11T09:00:00Z",
   "ehosctl": {"checked_at": "2026-10-11T09:00:00Z", "newest": "0.2.0"},
   "installations": {"https://ehos.example.com": {"checked_at": "…", "version": "0.5.0",
                     "requires": ">= 0.3.0-dev", "produces": ["ehos.api/v1"]}}}
  ```
  """

  alias Ehosctl.Acceptance
  alias Ehosctl.Api
  alias Ehosctl.Config
  alias Ehosctl.Credentials
  alias Ehosctl.GitHub
  alias Ehosctl.HTTP
  alias Ehosctl.PrivateFile

  @day 24 * 3600
  @timeout_ms 2_000
  @file_name "notice.json"
  @version 1

  # An installation not used for a week is forgotten, so the file does not grow without end.
  @forgotten_after 7 * @day

  @typedoc """
  What the command was: its `command` name, whether it printed JSON (`json?`), and the
  `installation` it talked to, or `nil`.
  """
  @type context :: %{
          command: atom(),
          json?: boolean(),
          installation: {Config.name(), Config.installation()} | nil
        }

  @doc """
  Prints the notice when one is due, after the command `context` describes. Always `:ok`.

  `opts` may name, for the tests, `:cache_dir`, and what `Ehosctl.GitHub` and `Ehosctl.Credentials`
  take.
  """
  @spec after_command(context(), keyword()) :: :ok
  def after_command(context, opts) do
    env = Ehosctl.SystemEnv.current().all()

    unless silent?(context, env), do: notice(context, opts)
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  @doc """
  Whether the notice stays silent after the command `context` describes, in `env`.
  """
  @spec silent?(context(), %{String.t() => String.t()}) :: boolean()
  def silent?(context, env) do
    (env["CI"] || "") != "" or Map.has_key?(env, "EHOSCTL_NO_UPDATE_NOTICE") or context.json? or
      context.command in [:versions, :changelog] or
      not Ehosctl.Terminal.current().error_terminal?()
  end

  defp notice(context, opts) do
    now = Ehosctl.Clock.current().now()
    dir = Keyword.get_lazy(opts, :cache_dir, fn -> :filename.basedir(:user_cache, "ehosctl") end)
    url = with {_name, %{"url" => url}} <- context.installation, do: url

    cache = read(dir)

    # Nothing is asked or said unless the cache can be written first: a cache directory that
    # cannot keep what was learned would mean asking GitHub, and saying so, after every command.
    if work?(cache, context.installation, now) and write(dir, cache) == :ok do
      refreshed = refresh(cache, context.installation, now, opts)
      lines = lines(refreshed, url && refreshed.installations[url], context.installation)

      if lines != [] and due?(refreshed.noticed_at, now) do
        Enum.each(lines, &warn/1)
        write(dir, %{refreshed | noticed_at: now})
      else
        write_if_changed(dir, cache, refreshed)
      end
    end
  end

  # Whether a source is to be asked again, or a notice is due from what is known already.
  defp work?(cache, chosen, now) do
    url = with {_name, %{"url" => url}} <- chosen, do: url

    stale(cache, url, now) != [] or
      (due?(cache.noticed_at, now) and lines(cache, url && cache.installations[url], chosen) != [])
  end

  defp stale(cache, url, now) do
    [
      not checked?(cache.ehosctl, now) && :ehosctl,
      (url != nil and not checked?(cache.installations[url], now)) && {:installation, url}
    ]
    |> Enum.filter(& &1)
  end

  defp due?(nil, _now), do: true
  defp due?(noticed_at, now), do: not recent?(noticed_at, now)

  defp recent?(at, now) do
    seconds = DateTime.diff(now, at)
    seconds >= 0 and seconds < @day
  end

  @doc """
  The warnings of the notice from what is known, each its head and its explanation: `ehosctl`'s
  newest release when it is newer than this one, and the installation's `requires` and `produces`
  when they refuse this one.
  """
  @spec lines(map(), map() | nil, {Config.name(), Config.installation()} | nil) ::
          [{String.t(), String.t()}]
  def lines(cache, installation, chosen) do
    own = Ehosctl.version()

    newer =
      case cache.ehosctl do
        %{newest: newest} when is_binary(newest) ->
          if Version.compare(newest, own) == :gt,
            do:
              {"ehosctl #{newest} is released, and this ehosctl is #{own}.",
               "Run `#{Ehosctl.upgrade_command(newest)}`, and `ehosctl changelog ehosctl` to " <>
                 "see what changed."}

        _unknown ->
          nil
      end

    refused =
      with %{produces: produces} <- installation,
           {name, _installation} <- chosen,
           requires = if(installation[:requires], do: %{"ehosctl" => installation[:requires]}),
           described = %{"produces" => produces, "requires" => requires || %{}},
           {:no, why} <- Acceptance.ehosctl(described, own, Ehosctl.Version.accepts()) do
        # The reason stays after "this ehosctl": its "it" is this ehosctl.
        {"#{name} runs EHOS #{installation[:version] || "of a version it did not say"}, which " <>
           "does not accept this ehosctl (#{own}): #{why}.",
         "`ehosctl versions` says whether it accepts the newest release."}
      else
        _accepted -> nil
      end

    Enum.filter([newer, refused], &is_tuple/1)
  end

  defp warn({head, explanation}), do: Ehosctl.Output.warn(head, explanation)

  # Each source asked again when what is known of it is older than a day, both at once, and
  # whatever has not answered in two seconds left for another day.
  defp refresh(cache, chosen, now, opts) do
    opts = Keyword.put(opts, :timeout, @timeout_ms)
    url = with {_name, %{"url" => url}} <- chosen, do: url

    asks =
      Enum.map(stale(cache, url, now), fn
        :ehosctl -> {:ehosctl, fn -> newest(opts) end}
        {:installation, _url} = key -> {key, fn -> described(chosen, opts) end}
      end)

    tasks = Enum.map(asks, fn {key, ask} -> {key, Task.async(fn -> safely(ask) end)} end)
    answers = Task.yield_many(Enum.map(tasks, &elem(&1, 1)), @timeout_ms)

    tasks
    |> Enum.zip(answers)
    |> Enum.reduce(cache, fn {{key, task}, {task, answer}}, cache ->
      answer =
        case answer do
          {:ok, answer} ->
            answer

          _none ->
            Task.shutdown(task, :brutal_kill)
            :unknown
        end

      put(cache, key, answer, now)
    end)
    |> forget_old(now)
  end

  defp safely(ask) do
    ask.()
  rescue
    _exception -> :unknown
  catch
    _kind, _reason -> :unknown
  end

  defp checked?(%{checked_at: at}, now), do: recent?(at, now)
  defp checked?(_entry, _now), do: false

  defp newest(opts) do
    case GitHub.releases("ehosctl", opts) do
      {:ok, [newest | _]} -> {:newest, newest.version}
      {:ok, []} -> {:newest, nil}
      {:error, _kind, _message} -> :unknown
    end
  end

  # Only with a credential already cached: a renewal could prompt or take the lock.
  defp described({_name, %{"url" => url}} = chosen, opts) do
    with token when is_binary(token) <- Credentials.cached_credential(chosen, opts),
         {:ok, %{status: 200, body: body}} <-
           HTTP.current().request(:get, url <> "/api/v1", token, nil, opts),
         {:ok, described} <- Api.described(body) do
      {:described, described}
    else
      _unknown -> :unknown
    end
  end

  # What was not learned keeps what was known, and is asked again a day later.
  defp put(cache, :ehosctl, answer, now) do
    newest =
      case answer do
        {:newest, newest} -> newest
        :unknown -> cache.ehosctl[:newest]
      end

    %{cache | ehosctl: %{checked_at: now, newest: newest}}
  end

  defp put(cache, {:installation, url}, answer, now) do
    entry =
      case answer do
        {:described, described} ->
          %{
            checked_at: now,
            version: described["version"],
            requires: described["requires"]["ehosctl"],
            produces: described["produces"]
          }

        :unknown ->
          Map.put(cache.installations[url] || %{}, :checked_at, now)
      end

    put_in(cache.installations[url], entry)
  end

  defp forget_old(cache, now) do
    kept =
      cache.installations
      |> Enum.filter(fn {_url, %{checked_at: at}} ->
        DateTime.diff(now, at) < @forgotten_after
      end)
      |> Map.new()

    %{cache | installations: kept}
  end

  defp empty, do: %{noticed_at: nil, ehosctl: nil, installations: %{}}

  @doc """
  The cache in `dir`, every part of it checked: a part of another shape is dropped, and a file
  that is not the cache at all is read as empty.
  """
  @spec read(Path.t()) :: map()
  def read(dir) do
    path = Path.join(dir, @file_name)

    with {:ok, %{type: :regular, size: size}} when size < 1_048_576 <- File.lstat(path),
         {:ok, contents} <- File.read(path),
         {:ok, %{"version" => @version} = cache} <- JSON.decode(contents) do
      %{
        noticed_at: moment(cache["noticed_at"]),
        ehosctl: ehosctl_entry(cache["ehosctl"]),
        installations:
          case cache["installations"] do
            %{} = installations ->
              for {url, entry} <- installations,
                  is_binary(url),
                  entry = installation_entry(entry),
                  entry != nil,
                  into: %{},
                  do: {url, entry}

            _other ->
              %{}
          end
      }
    else
      _other -> empty()
    end
  end

  defp ehosctl_entry(%{"checked_at" => at} = entry) do
    with %DateTime{} = at <- moment(at),
         newest when is_nil(newest) or is_binary(newest) <- entry["newest"],
         true <- is_nil(newest) or match?({:ok, _}, Version.parse(newest)) do
      %{checked_at: at, newest: newest}
    else
      _other -> nil
    end
  end

  defp ehosctl_entry(_entry), do: nil

  defp installation_entry(%{"checked_at" => at} = entry) do
    with %DateTime{} = at <- moment(at) do
      version = entry["version"]
      requires = entry["requires"]
      produces = entry["produces"]

      if (is_nil(version) or printable?(version)) and (is_nil(requires) or printable?(requires)) and
           (is_nil(produces) or (is_list(produces) and Enum.all?(produces, &printable?/1))) do
        %{checked_at: at, version: version, requires: requires, produces: produces}
        |> Map.reject(&is_nil(elem(&1, 1)))
      end
    end
  end

  defp installation_entry(_entry), do: nil

  defp printable?(text), do: is_binary(text) and Ehosctl.Output.printable?(text)

  defp moment(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      _error -> nil
    end
  end

  defp moment(_value), do: nil

  defp write_if_changed(_dir, cache, cache), do: :ok
  defp write_if_changed(dir, _cache, refreshed), do: write(dir, refreshed)

  defp write(dir, cache) do
    contents = %{
      "version" => @version,
      "noticed_at" => cache.noticed_at && DateTime.to_iso8601(cache.noticed_at),
      "ehosctl" =>
        cache.ehosctl &&
          %{
            "checked_at" => DateTime.to_iso8601(cache.ehosctl.checked_at),
            "newest" => cache.ehosctl.newest
          },
      "installations" =>
        Map.new(cache.installations, fn {url, entry} ->
          {url,
           entry
           |> Map.update!(:checked_at, &DateTime.to_iso8601/1)
           |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)}
        end)
    }

    with :ok <- PrivateFile.make_dir(dir),
         do: PrivateFile.write(Path.join(dir, @file_name), JSON.encode!(contents))
  end
end
