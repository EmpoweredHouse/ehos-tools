defmodule Ehosctl.Changelog do
  @moduledoc """
  `ehosctl changelog <component> [--since VERSION] [--web]`: what changed in a component's
  releases newer than a version, newest first, each under its version, from GitHub's releases
  (eh-os D-91, ehos-tools#97). A release's notes are its changelog section, as its release
  published them (`Ehosctl.GitHub.notes/2`).

  The version defaults to the one in use: `ehosctl`'s own; for `ehos`, the version the chosen
  installation says it runs (`GET /api/v1`); for `ehos_app`, `eh_os_contract` and `ehos_design`,
  the one the application in the current directory locks, as `ehosctl versions` reads it. When
  that cannot be found, `--since` is asked for. `--web` opens the newest release's page instead,
  and prints its address.

  It is on the governed plane, as `versions` is, since it may ask the installation which EHOS it
  runs, and chooses its installation itself, so it also runs without one.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.Config
  alias Ehosctl.GitHub
  alias Ehosctl.Output
  alias Ehosctl.Project
  alias Ehosctl.Refusal
  alias Ehosctl.Versions

  # The most releases whose notes one run reads and prints, newest first.
  @max_printed 50

  @impl Ehosctl.Command
  def name, do: :changelog

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def chooses_installation?, do: true

  @impl Ehosctl.Command
  def spec,
    do: [
      about:
        "Print what changed in a component's releases newer than the version in use, " <>
          "newest first.",
      args: [
        component: [
          value_name: "COMPONENT",
          required: true,
          help: "One of #{Enum.join(GitHub.components(), ", ")}."
        ]
      ],
      options: [
        since: [
          long: "--since",
          value_name: "VERSION",
          help: "Print the releases newer than this version, instead of the one in use."
        ]
      ],
      flags:
        [web: [long: "--web", help: "Open the newest release's page in the browser instead."]] ++
          Output.json_flag()
    ]

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], parsed, opts) do
    component = parsed.args.component

    with :ok <- known(component),
         {:ok, since} <- given(parsed.options[:since]),
         {:ok, releases} <- GitHub.releases(component, opts) do
      if parsed.flags.web,
        do: web(component, releases, opts),
        else: notes(component, since, releases, parsed, opts)
    end
  end

  defp known(component) do
    if component in GitHub.components(),
      do: :ok,
      else:
        {:error, :invalid,
         "#{Refusal.shown(component)} is not a component: name one of " <>
           "#{Enum.join(GitHub.components(), ", ")}."}
  end

  defp given(nil), do: {:ok, nil}

  defp given(since) do
    case since |> String.replace_prefix("v", "") |> Version.parse() do
      {:ok, version} -> {:ok, to_string(version)}
      :error -> {:error, :invalid, "--since #{Refusal.shown(since)} is not a version."}
    end
  end

  defp web(component, [newest | _], opts) do
    # Waited for: the binary halts as soon as the command returns.
    open = Keyword.get(opts, :open_browser, &Ehosctl.Browser.open(&1, wait: true))
    open.(newest.url)
    {:ok, %{text: newest.url, json: %{component: component, url: newest.url}}}
  end

  defp web(component, [], _opts), do: {:error, :failed, "#{component} has no release yet."}

  defp notes(component, since, releases, parsed, opts) do
    with {:ok, since} <-
           if(since, do: {:ok, since}, else: in_use(component, releases, parsed, opts)) do
      newer = Enum.filter(releases, &(Version.compare(&1.version, since) == :gt))
      {printed, left_out} = Enum.split(newer, @max_printed)

      read =
        printed
        |> Task.async_stream(&{&1, GitHub.notes(&1, opts)},
          timeout: :infinity,
          max_concurrency: 4
        )
        |> Enum.map(fn {:ok, read} -> read end)

      text =
        case left_out do
          [] ->
            text(component, since, releases, read)

          _more ->
            text(component, since, releases, read) <>
              "\n\n#{length(left_out)} older releases newer than #{since}, up to " <>
              "#{hd(left_out).version}, are left out: their notes are at " <>
              "https://github.com/#{GitHub.repository(component)}/releases."
        end

      {:ok,
       %{text: text, json: Map.put(json(component, since, read), :left_out, length(left_out))}}
    end
  end

  # The version in use, as `versions` finds it, or a request for --since that says why not.
  defp in_use("ehosctl", _releases, _parsed, _opts), do: {:ok, Ehosctl.version()}

  defp in_use("ehos", _releases, parsed, opts) do
    with {:ok, chosen} <- Config.chosen(parsed.options[:installation], opts) do
      case chosen && Api.describe(chosen, opts) do
        nil ->
          since_needed("ehos", "no installation is chosen to say which EHOS it runs")

        {:ok, %{"version" => version}} ->
          {:ok, version}

        {:ok, :predates} ->
          since_needed("ehos", "the installation has no GET /api/v1 to say")

        {:error, _kind, message} ->
          since_needed("ehos", "the installation did not say: #{message}")
      end
    end
  end

  defp in_use(component, releases, _parsed, opts) do
    dir = Keyword.get_lazy(opts, :dir, &File.cwd!/0)

    case Project.read(dir) do
      {:ok, %{deps: %{^component => dependency}}} ->
        version =
          Versions.locked_version(component, dependency) ||
            matched_version(component, dependency, releases, opts)

        if version,
          do: {:ok, version},
          else:
            since_needed(
              component,
              "this application locks it at #{short(dependency)}, which is no release's"
            )

      {:ok, _project} ->
        since_needed(component, "this application does not depend on it")

      :none ->
        since_needed(component, "#{Refusal.shown(dir)} is not an application's directory")

      {:error, message} ->
        since_needed(component, message)
    end
  end

  # The release whose release.json names the locked commit, else the tag that names it, read as
  # `versions` reads them.
  defp matched_version(component, %{scm: :git} = dependency, releases, opts) do
    located = Versions.located(dependency, releases, opts)

    case Versions.matched(dependency, releases, located) ||
           Versions.tagged(component, dependency, opts) do
      %{version: version} -> version
      nil -> nil
    end
  end

  defp matched_version(_component, _dependency, _releases, _opts), do: nil

  defp short(%{commit: commit}), do: String.slice(commit, 0, 7)
  defp short(%{version: version}), do: version

  defp since_needed(component, why),
    do:
      {:error, :invalid,
       "The #{component} in use is not known: #{String.trim_trailing(why, ".")}. Say which " <>
         "version to start after with --since."}

  defp text(component, since, releases, []) do
    case releases do
      [] -> "#{component} has no release yet."
      [newest | _] -> "Nothing newer than #{since}: the newest #{component} is #{newest.version}."
    end
  end

  defp text(component, _since, _releases, read) do
    Enum.map_join(read, "\n\n", fn {release, notes} ->
      published = if release.published_at, do: " (#{String.slice(release.published_at, 0, 10)})"

      heading = "# #{component} #{release.version}#{published}\n#{release.url}"

      body =
        case notes do
          {:ok, notes} -> shown(notes)
          {:error, _kind, message} -> "Its notes could not be read: #{message}"
        end

      heading <> "\n\n" <> body
    end)
  end

  # Notes are Markdown written by people, printed as they are, but a line a terminal would act
  # on is printed quoted with its escapes.
  defp shown(notes) do
    notes
    |> String.replace("\r\n", "\n")
    |> String.replace("\t", "    ")
    |> String.trim()
    |> String.split("\n")
    |> Enum.map_join("\n", &Refusal.shown/1)
  end

  defp json(component, since, read) do
    %{
      component: component,
      since: since,
      releases:
        Enum.map(read, fn {release, notes} ->
          %{
            version: release.version,
            tag: release.tag,
            url: release.url,
            published_at: release.published_at,
            notes:
              case notes do
                {:ok, notes} -> notes
                {:error, _kind, _message} -> nil
              end,
            unread:
              case notes do
                {:ok, _notes} -> nil
                {:error, _kind, message} -> message
              end
          }
        end)
    }
  end
end
