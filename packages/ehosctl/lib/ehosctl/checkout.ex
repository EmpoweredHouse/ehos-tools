defmodule Ehosctl.Checkout do
  @moduledoc """
  What a GitHub Actions job states of the build it registers, read from its checkout and from the
  event that started it ([T-19](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0019-ehosctl-builds-register-states-what-a-github-actions-job-s-checkout-and-event-say-of-its-commit-and-elsewhere-nothing.md), eh-os
  [D-146](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0146-a-build-is-a-record-of-its-own-registered-by-ci-with-the-commit-it-came-from-a-deployment-names-a-build-and-a-promotion-s-review-links-to-what-changed.md),
  [`docs/builds-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/builds-api.md#what-a-run-or-a-person-states)):

    * `title`, `author` and `committed_at`: the commit's first line, its author's name and its
      committer's time, in UTC;
    * `pull_request`, for a pull request's run: its number, head commit and title, from the event;
    * `commits`: the commits before it, newest first, along first parents, at most 100, each its
      commit and first line.

  The commit is the one the run is of: `GITHUB_SHA` on a push, and the pull request's head on a
  `pull_request` run, since `GITHUB_SHA` is then GitHub's test merge, whose first line says only
  that it merges, and whose first parents are the base branch's. A `pull_request_target` run is
  of the base's commit, `GITHUB_SHA`, and states its pull request beside it. A pull request's
  checkout needs one commit more of history than a push's for the 100 before the head:
  `fetch-depth: 102`. The commit and ref a build is of
  are not stated: a pipeline's are GitHub's token's, and EHOS refuses them stated.

  EHOS checks a stated field's form, never its truth, and refuses one outside it. So a field is
  made to fit, never to fail the pipeline: a title or a name loses every control character and
  every mark that sets the direction of text (U+200E, U+200F, U+061C, U+202A to U+202E, U+2066 to
  U+2069), is normalised to NFC, and is shortened to 256 code points on a character's boundary; a
  time later than this clock, which a committer's clock running fast makes, is left out; and
  whatever cannot be read, from a shallow checkout or without git, is left out too.

  Outside a GitHub Actions job nothing is stated: a person's checkout has no tie to the image they
  register, as `ehosctl deploy` never states a checkout's commit (eh-os D-129).
  """

  @max_text 256
  @max_commits 100
  @max_number 2_147_483_647
  # A pull request's event is a few kilobytes; one past this is not read.
  @max_event_bytes 4_194_304

  @commit ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @stripped ~r/[\p{Cc}\x{200E}\x{200F}\x{061C}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u

  @pull_request_events ~w(pull_request pull_request_target)

  @doc """
  The stated fields of a build registered from the checkout in `dir`, in the job `env` describes,
  at `now`; an empty map outside a GitHub Actions job. Never fails: a field that cannot be read is
  left out.
  """
  @spec stated(%{String.t() => String.t()}, String.t(), DateTime.t()) :: map()
  def stated(env, dir, now \\ DateTime.utc_now())

  def stated(%{"GITHUB_ACTIONS" => "true"} = env, dir, now) do
    pull_request = pull_request(env)

    # `pull_request_target` runs the base's workflow at the base's commit: the build is of that.
    commit =
      if env["GITHUB_EVENT_NAME"] == "pull_request" and pull_request["head"],
        do: pull_request["head"],
        else: commit(env["GITHUB_SHA"])

    %{"pull_request" => pull_request}
    |> Map.merge(if commit, do: log(dir, commit, now), else: %{})
    |> Map.reject(fn {_field, value} -> value in [nil, [], %{}] end)
  end

  def stated(_env, _dir, _now), do: %{}

  @doc """
  `value` as EHOS takes a stated title or name: without control characters or marks of direction,
  in NFC, at most 256 code points, cut on a character's boundary; `nil` when nothing is left.

      iex> Ehosctl.Checkout.text("Lend a book\\u202E for longer\\r")
      "Lend a book for longer"

      iex> Ehosctl.Checkout.text("Mu\\u0308ller")
      "Müller"

      iex> Ehosctl.Checkout.text(String.duplicate("é", 300)) |> String.length()
      256

      iex> Ehosctl.Checkout.text("\\u200F")
      nil
  """
  @spec text(String.t()) :: String.t() | nil
  def text(value) do
    value
    |> String.replace_invalid()
    |> String.replace(@stripped, "")
    |> :unicode.characters_to_nfc_binary()
    |> String.trim()
    |> shortened()
    |> case do
      "" -> nil
      text -> text
    end
  end

  # Code points, as EHOS counts them, taken a whole character at a time.
  defp shortened(text) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn grapheme, {kept, count} ->
      count = count + length(String.to_charlist(grapheme))

      if count > @max_text,
        do: {:halt, {kept, count}},
        else: {:cont, {[grapheme | kept], count}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  ## The event

  defp pull_request(%{"GITHUB_EVENT_NAME" => event, "GITHUB_EVENT_PATH" => path})
       when event in @pull_request_events do
    case event(path) do
      {:ok, %{"pull_request" => %{} = pull_request}} ->
        %{
          "number" => number(pull_request["number"]),
          "head" => commit(get_in(pull_request, ["head", "sha"])),
          "title" => if(is_binary(pull_request["title"]), do: text(pull_request["title"]))
        }
        |> Map.reject(fn {_field, value} -> is_nil(value) end)
        |> case do
          empty when empty == %{} -> nil
          pull_request -> pull_request
        end

      _unread ->
        nil
    end
  end

  defp pull_request(_env), do: nil

  defp event(path) do
    with {:ok, %{type: :regular, size: size}} when size <= @max_event_bytes <- File.stat(path),
         {:ok, bytes} <- File.read(path) do
      JSON.decode(bytes)
    end
  end

  defp number(number) when is_integer(number) and number in 1..@max_number, do: number
  defp number(_number), do: nil

  defp commit(commit) when is_binary(commit),
    do: if(Regex.match?(@commit, commit), do: commit)

  defp commit(_commit), do: nil

  ## The log

  # The commit and the 100 before it along first parents, each its hash, its author, its
  # committer's time and its message, one record each, separated by NUL, which a message cannot
  # hold.
  defp log(dir, commit, now) do
    args =
      ~w(log -z --first-parent --no-color --no-show-signature) ++
        ["--max-count=#{@max_commits + 1}", "--format=%H%n%an%n%cI%n%B", commit, "--"]

    case git(dir, args) do
      {:ok, output} ->
        case output |> String.split(<<0>>, trim: true) |> Enum.map(&record/1) do
          [{^commit, author, time, title} | before] ->
            %{
              "title" => title,
              "author" => author && text(author),
              "committed_at" => committed_at(time, now),
              "commits" => before(before)
            }

          _other ->
            %{}
        end

      :error ->
        %{}
    end
  end

  # What git says on stderr is kept from the person's terminal: a failure states nothing, and a
  # read with a warning in it fails to parse, and states nothing either.
  defp git(dir, args) do
    case Ehosctl.Runner.current().run("git", ["-C", dir | args], []) do
      {output, 0} -> {:ok, output}
      _failed -> :error
    end
  rescue
    _no_git -> :error
  end

  defp record(record) do
    case String.split(record, "\n", parts: 4) do
      [hash, author, time, message] -> {hash, author, time, first_line(message)}
      [hash, author, time] -> {hash, author, time, nil}
      _other -> {nil, nil, nil, nil}
    end
  end

  defp first_line(message), do: message |> String.split("\n", parts: 2) |> hd() |> text()

  # Each a commit and its first line, which EHOS requires: the list stops before the first that
  # has none, so what it lists is still the commits before this one, in order.
  defp before(records) do
    records
    |> Enum.take_while(fn {hash, _author, _time, title} -> commit(hash) && title end)
    |> Enum.map(fn {hash, _author, _time, title} -> %{"commit" => hash, "title" => title} end)
  end

  defp committed_at(time, now) when is_binary(time) do
    with {:ok, at, _offset} <- DateTime.from_iso8601(time),
         at = at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second),
         true <- DateTime.compare(at, now) != :gt do
      DateTime.to_iso8601(at)
    else
      _later_or_unread -> nil
    end
  end

  defp committed_at(_time, _now), do: nil
end
