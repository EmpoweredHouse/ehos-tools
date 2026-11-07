defmodule EhosApp.Plugins do
  @moduledoc """
  Checks that this machine holds the Claude Code plugins a repository pins (ehos-tools T-22).

  A repository pins a marketplace by the `ref` of its entry in `extraKnownMarketplaces`, in
  `.claude/settings.json`: eh-os, ehos-tools and eh-os-contract pin `ehos-tools` at a tag
  `ehos-dev-vX.Y.Z`, and an application pins `ehos-app` at `ehos-app-vX.Y.Z`. Claude Code applies
  that `ref` only when it adds the marketplace: a machine that already has it keeps the tag it
  added it at, and its sessions load the plugins of that tag, older than the pin, without a word.

  `check/2` compares the pins with what `claude` reports, and says what is behind and the
  commands that move the machine. The review gate runs it before a pull request
  (`EhosApp.Review.gate/2`), and a `SessionStart` hook runs it at the start of each session.
  """

  @marketplaces ["plugin", "marketplace", "list", "--json"]
  @plugins ["plugin", "list", "--json"]

  @typedoc "`:claude`: the `EhosApp.Claude` to ask, `EhosApp.ClaudeImpl` unless given."
  @type option :: {:claude, module()}

  @doc """
  Returns `:ok` when this machine holds each marketplace that `dir`'s `.claude/settings.json`
  pins by `ref`, from the same repository at the same `ref`, and each plugin it enables whose
  name the `ref` carries (`ehos-dev` in `ehos-dev-v0.12.0`) installed at that version.

  Returns `:ok` too when `dir` has no `.claude/settings.json`, when it pins no marketplace, and
  when `claude` is not installed, as in CI, where there is nothing to compare.

  Otherwise returns `{:error, message}`: what the machine holds against what the repository pins,
  and the commands that move the machine; or that the settings are not JSON, that `claude` failed,
  or that its answer has a shape this check cannot read.
  """
  @spec check(Path.t(), [option()]) :: :ok | {:error, String.t()}
  def check(dir, opts \\ []) do
    claude = Keyword.get(opts, :claude, EhosApp.ClaudeImpl)

    with {:ok, [_ | _] = pins} <- pins(dir),
         {:ok, held} <- ask(claude, @marketplaces, dir),
         :ok <- marketplaces_held(pins, held),
         {:ok, installed} <- ask(claude, @plugins, dir) do
      plugins_installed(pins, installed)
    else
      {:ok, []} -> :ok
      :not_installed -> :ok
      {:error, message} -> {:error, message}
    end
  end

  defp pins(dir) do
    path = Path.join([dir, ".claude", "settings.json"])

    with {:ok, text} <- read(path),
         {:ok, %{} = settings} <- decode(text) do
      {:ok, pins_in(settings)}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, _reason} -> {:ok, "{}"}
    end
  end

  defp decode(text) do
    case JSON.decode(text) do
      {:ok, %{} = settings} -> {:ok, settings}
      _other -> {:error, "cannot read .claude/settings.json: it is not a JSON object"}
    end
  end

  defp pins_in(settings) do
    enabled = enabled(settings["enabledPlugins"])

    for {name, %{"source" => %{"ref" => ref} = source}} <- marketplaces(settings),
        is_binary(ref) do
      %{
        marketplace: name,
        location: source["repo"] || source["url"],
        ref: ref,
        enabled: Enum.filter(enabled, &String.ends_with?(&1, "@" <> name))
      }
    end
  end

  defp marketplaces(%{"extraKnownMarketplaces" => %{} = marketplaces}), do: marketplaces
  defp marketplaces(_settings), do: %{}

  defp enabled(%{} = plugins), do: Enum.sort(for({id, true} <- plugins, do: id))
  defp enabled(_plugins), do: []

  defp ask(claude, args, dir) do
    case claude.run(args, dir) do
      {:ok, output} ->
        list(JSON.decode(output), args)

      {:error, :not_installed} ->
        :not_installed

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
    case Enum.reject(pins, &held?(&1, held)) do
      [] -> :ok
      behind -> {:error, Enum.map_join(behind, "\n\n", &marketplace_message(&1, held))}
    end
  end

  defp held?(pin, held) do
    Enum.any?(held, fn entry ->
      entry["name"] == pin.marketplace and entry["ref"] == pin.ref and
        (entry["repo"] || entry["url"]) == pin.location
    end)
  end

  defp marketplace_message(pin, held) do
    case Enum.find(held, &(&1["name"] == pin.marketplace)) do
      nil ->
        "This machine does not have the marketplace #{pin.marketplace}, which this repository " <>
          "pins at #{pin.ref}. To add it:\n\n" <> steps(pin, 1)

      entry ->
        "This machine has the marketplace #{pin.marketplace} at #{held_at(entry)}, and this " <>
          "repository pins it at #{pin.ref}. Claude Code loads the plugins of the tag the machine " <>
          "has. To move the machine to the pinned tag:\n\n" <>
          "1. In a directory outside every checkout, run " <>
          "`claude plugin marketplace remove #{pin.marketplace}`. In a checkout, this command " <>
          "also deletes the marketplace from the checkout's `.claude/settings.json`.\n" <>
          steps(pin, 2)
    end
  end

  defp held_at(%{"ref" => ref}) when is_binary(ref), do: ref
  defp held_at(_entry), do: "its default branch"

  defp steps(pin, first) do
    installs =
      Enum.map_join(pin.enabled, " and ", &"`claude plugin install #{&1} --scope project`")

    "#{first}. Run `claude plugin marketplace add #{pin.location}##{pin.ref}`.\n" <>
      "#{first + 1}. In this checkout, run #{installs}.\n" <>
      "#{first + 2}. Restart Claude Code."
  end

  defp plugins_installed(pins, installed) do
    case for(
           pin <- pins,
           {id, version} <- versioned(pin),
           not installed?(installed, id, version),
           do: {id, version}
         ) do
      [] -> :ok
      missing -> {:error, Enum.map_join(missing, "\n\n", &plugin_message(&1, installed))}
    end
  end

  # The plugin whose version the tag names: `ehos-dev@ehos-tools` at 0.12.0 for
  # `ehos-dev-v0.12.0`. A plugin the tag does not name, such as `diagram-design`, has no version
  # to compare.
  defp versioned(pin) do
    for id <- pin.enabled,
        [plugin, _marketplace] = String.split(id, "@", parts: 2),
        String.starts_with?(pin.ref, plugin <> "-v"),
        do: {id, String.replace_prefix(pin.ref, plugin <> "-v", "")}
  end

  defp installed?(installed, id, version),
    do: Enum.any?(installed, &(&1["id"] == id and &1["version"] == version))

  defp plugin_message({id, version}, installed) do
    held =
      for %{"id" => ^id, "version" => held} <- installed, is_binary(held), uniq: true, do: held

    "This machine has #{held_text(held)} of #{id}, and this repository pins #{version}. In this " <>
      "checkout, run `claude plugin install #{id} --scope project`, then restart Claude Code."
  end

  defp held_text([]), do: "no version"
  defp held_text(versions), do: "version " <> Enum.join(versions, ", ")
end
