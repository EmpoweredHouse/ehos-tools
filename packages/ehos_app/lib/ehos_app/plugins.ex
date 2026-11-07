defmodule EhosApp.Plugins do
  @moduledoc """
  Checks that this machine holds the Claude Code plugins a repository pins, or later ones
  (ehos-tools T-22).

  A repository pins a marketplace by the `ref` of its entry in `extraKnownMarketplaces`, in
  `.claude/settings.json`: eh-os, ehos-tools and eh-os-contract pin `ehos-tools` at a tag
  `ehos-dev-vX.Y.Z`, and an application pins `ehos-app` at `ehos-app-vX.Y.Z`. Claude Code applies
  that `ref` only when it adds the marketplace: a machine that already has it keeps the tag it
  added it at, and its sessions load the plugins of that tag, older than the pin, without a word.

  `check/2` compares the pins with what `claude` reports, and says what is behind and the
  commands that move the machine. A machine ahead of a pin passes, with a note: the marketplace
  is one per machine, and repositories move their pins one at a time. The review gate runs the
  check before it records a review and before a pull request (`EhosApp.Review`), and ehos-tools'
  `SessionStart` hook runs it at the start of each session.

  Every name, `ref` and repository the check prints is first held to a plain form, since its
  message reaches an assistant as the commands to run.
  """

  @marketplaces ["plugin", "marketplace", "list", "--json"]
  @plugins ["plugin", "list", "--json"]

  @name ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @plugin_id ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*@[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @ref ~r/\A[A-Za-z0-9][A-Za-z0-9._\/-]*\z/
  @location ~r/\A[A-Za-z0-9][A-Za-z0-9._\/:@-]*\z/
  @versioned_ref ~r/\A(?<plugin>.+)-v(?<version>\d+\.\d+\.\d+)\z/

  @typedoc "`:claude`: the `EhosApp.Claude` to ask, `EhosApp.ClaudeImpl` unless given."
  @type option :: {:claude, module()}

  @doc """
  Returns `{:ok, notes}` when this machine holds each marketplace that `dir`'s
  `.claude/settings.json` pins by `ref`, from the same repository, at that `ref` or at a later
  version of the same tag, and each plugin it enables whose name the `ref` carries (`ehos-dev`
  in `ehos-dev-v0.12.0`) installed for `dir` or for the user at that version or later. `notes`
  say which marketplaces the machine holds at a later tag than the pin.

  `dir` is the top of a working tree. Returns `{:ok, []}` too when it has no
  `.claude/settings.json`, when it pins no marketplace, and when `claude` is not installed, as in
  CI, where there is nothing to compare.

  Otherwise returns `{:error, message}`: what the machine holds against what the repository pins,
  and the commands that move the machine; or that the settings cannot be read or name a
  marketplace or plugin in a form the check does not print, that `claude` failed or did not
  answer, or that its answer has a shape this check cannot read.
  """
  @spec check(Path.t(), [option()]) :: {:ok, [String.t()]} | {:error, String.t()}
  def check(dir, opts \\ []) do
    claude = Keyword.get(opts, :claude, EhosApp.ClaudeImpl)

    with {:ok, [_ | _] = pins} <- pins(dir),
         {:ok, held} <- ask(claude, @marketplaces, dir),
         {:ok, notes} <- marketplaces_held(pins, held),
         {:ok, installed} <- ask(claude, @plugins, dir),
         :ok <- plugins_installed(pins, installed, dir) do
      {:ok, notes}
    else
      {:ok, []} -> {:ok, []}
      :not_installed -> {:ok, []}
      {:error, message} -> {:error, message}
    end
  end

  defp pins(dir) do
    with {:ok, text} <- read(Path.join([dir, ".claude", "settings.json"])),
         {:ok, settings} <- decode(text) do
      settings |> pins_in() |> plain()
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, :enoent} -> {:ok, "{}"}
      {:error, _reason} -> {:error, "cannot read .claude/settings.json"}
    end
  end

  defp decode(text) do
    case JSON.decode(text) do
      {:ok, %{} = settings} -> {:ok, settings}
      _other -> {:error, "cannot read .claude/settings.json: it is not a JSON object"}
    end
  end

  # A marketplace from GitHub (`repo`) or a git URL (`url`) with a `ref`. One from a directory
  # names no `ref` a machine could hold, and is not compared.
  defp pins_in(settings) do
    enabled = enabled(settings["enabledPlugins"])

    for {name, %{"source" => %{"ref" => ref} = source}} <- marketplaces(settings),
        is_binary(ref),
        location = source["repo"] || source["url"],
        is_binary(location) do
      %{
        marketplace: name,
        location: location,
        ref: ref,
        enabled: Enum.filter(enabled, &String.ends_with?(&1, "@" <> name))
      }
    end
  end

  defp marketplaces(%{"extraKnownMarketplaces" => %{} = marketplaces}), do: marketplaces
  defp marketplaces(_settings), do: %{}

  defp enabled(%{} = plugins), do: Enum.sort(for({id, true} <- plugins, do: id))
  defp enabled(_plugins), do: []

  # What the check prints reaches an assistant as commands, so a value from the settings that is
  # not a plain name is refused, and not printed.
  defp plain(pins) do
    if Enum.all?(pins, &plain?/1),
      do: {:ok, pins},
      else:
        {:error,
         "cannot read .claude/settings.json: a marketplace or plugin in it has a name, ref or " <>
           "repository with characters this check does not print"}
  end

  defp plain?(pin) do
    Regex.match?(@name, pin.marketplace) and Regex.match?(@ref, pin.ref) and
      Regex.match?(@location, pin.location) and
      Enum.all?(pin.enabled, &Regex.match?(@plugin_id, &1))
  end

  defp ask(claude, args, dir) do
    case claude.run(args, dir) do
      {:ok, output} ->
        list(JSON.decode(output), args)

      {:error, :not_installed} ->
        :not_installed

      {:error, :timeout} ->
        {:error, "`claude #{Enum.join(args, " ")}` did not answer in time"}

      {:error, {:exit, status}} ->
        {:error, "`claude #{Enum.join(args, " ")}` failed with status #{status}"}
    end
  end

  defp list({:ok, entries}, args) when is_list(entries) do
    if Enum.all?(entries, &is_map/1), do: {:ok, entries}, else: unreadable(args)
  end

  defp list(_decoded, args), do: unreadable(args)

  defp unreadable(args) do
    {:error,
     "`claude #{Enum.join(args, " ")}` answered in a shape this check cannot read. Check the " <>
       "marketplaces and plugins by hand with `claude plugin marketplace list` and `claude plugin list`."}
  end

  defp marketplaces_held(pins, held) do
    compared =
      Enum.map(
        pins,
        &{&1, compare(&1, Enum.find(held, fn entry -> entry["name"] == &1.marketplace end))}
      )

    case for({pin, :behind} <- compared, do: marketplace_message(pin, held)) do
      [] -> {:ok, for({pin, {:ahead, ref}} <- compared, do: ahead_note(pin, ref))}
      messages -> {:error, Enum.join(messages, "\n\n")}
    end
  end

  defp compare(_pin, nil), do: :behind

  defp compare(pin, entry) do
    cond do
      (entry["repo"] || entry["url"]) != pin.location -> :behind
      entry["ref"] == pin.ref -> :same
      later?(entry["ref"], pin.ref) -> {:ahead, entry["ref"]}
      true -> :behind
    end
  end

  # A later version of the same plugin's tag: `ehos-dev-v0.13.0` against `ehos-dev-v0.12.0`.
  defp later?(held, pinned) when is_binary(held) do
    with %{"plugin" => plugin, "version" => held_version} <-
           Regex.named_captures(@versioned_ref, held),
         %{"plugin" => ^plugin, "version" => pinned_version} <-
           Regex.named_captures(@versioned_ref, pinned) do
      Version.compare(held_version, pinned_version) == :gt
    else
      _other -> false
    end
  end

  defp later?(_held, _pinned), do: false

  # `ref` is a later tag of the pinned one, so it has the plain form `@versioned_ref` reads.
  defp ahead_note(pin, ref) do
    "This machine has the marketplace #{pin.marketplace} at #{ref}, a later tag than " <>
      "#{pin.ref}, which this repository pins. Its sessions load the plugins of #{ref}."
  end

  defp marketplace_message(pin, held) do
    case Enum.find(held, &(&1["name"] == pin.marketplace)) do
      nil ->
        "This machine does not have the marketplace #{pin.marketplace}, which this repository " <>
          "pins at #{pin.ref}. To add it:\n\n" <> steps(pin, 1)

      entry ->
        "This machine has the marketplace #{pin.marketplace} #{held_at(entry)}, and this " <>
          "repository pins it at #{pin.ref} from #{pin.location}. Claude Code loads the plugins " <>
          "of the tag the machine has. To move the machine to the pinned tag:\n\n" <>
          "1. In a directory outside every checkout, run " <>
          "`claude plugin marketplace remove #{pin.marketplace}`. In a checkout, this command " <>
          "also deletes the marketplace from the checkout's `.claude/settings.json`.\n" <>
          steps(pin, 2)
    end
  end

  # What `claude` reports goes in the message only in a plain form.
  defp held_at(%{"ref" => ref}) when is_binary(ref) do
    if Regex.match?(@ref, ref), do: "at #{ref}", else: "at another tag"
  end

  defp held_at(_entry), do: "at its default branch"

  defp steps(pin, first) do
    [
      "Run `claude plugin marketplace add #{pin.location}##{pin.ref}`.",
      install_step(pin.enabled),
      "Restart Claude Code."
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.with_index(first)
    |> Enum.map_join("\n", fn {step, number} -> "#{number}. #{step}" end)
  end

  defp install_step([]), do: nil

  defp install_step(enabled) do
    installs = Enum.map_join(enabled, " and ", &"`claude plugin install #{&1} --scope project`")
    "In this checkout, run #{installs}."
  end

  defp plugins_installed(pins, installed, dir) do
    root = Path.expand(dir)

    missing =
      for pin <- pins,
          {id, version} <- versioned(pin),
          versions = installed_versions(installed, id, root),
          Enum.all?(versions, &older?(&1, version)),
          do: {id, version, versions}

    case missing do
      [] -> :ok
      _missing -> {:error, Enum.map_join(missing, "\n\n", &plugin_message/1)}
    end
  end

  # The plugin whose version the tag names: `ehos-dev@ehos-tools` at 0.12.0 for
  # `ehos-dev-v0.12.0`. A plugin the tag does not name, such as `diagram-design`, has no version
  # to compare.
  defp versioned(pin) do
    for id <- pin.enabled,
        [plugin, _marketplace] = String.split(id, "@", parts: 2),
        %{"plugin" => ^plugin, "version" => version} <- [
          Regex.named_captures(@versioned_ref, pin.ref)
        ],
        do: {id, version}
  end

  # What a session in `root` loads: the plugin installed for the user, or for this checkout.
  # `claude plugin list` lists every checkout's installs, and another's proves nothing here.
  defp installed_versions(installed, id, root) do
    for %{"id" => ^id, "version" => version} = entry <- installed,
        is_binary(version),
        entry["scope"] == "user" or same_dir?(entry["projectPath"], root),
        uniq: true,
        do: version
  end

  defp same_dir?(path, root) when is_binary(path), do: Path.expand(path) == root
  defp same_dir?(_path, _root), do: false

  defp older?(held, pinned) do
    case Version.parse(held) do
      {:ok, held} -> Version.compare(held, pinned) == :lt
      :error -> true
    end
  end

  defp plugin_message({id, version, held}) do
    "This machine has #{held_text(held)} of #{id} for this checkout, and this repository pins " <>
      "#{version}. In this checkout, run `claude plugin install #{id} --scope project`, then " <>
      "restart Claude Code."
  end

  defp held_text([]), do: "no version"

  defp held_text(versions) do
    if Enum.all?(versions, &Regex.match?(@name, &1)),
      do: "version " <> Enum.join(versions, ", "),
      else: "another version"
  end
end
