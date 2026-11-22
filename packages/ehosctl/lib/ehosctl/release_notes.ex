defmodule Ehosctl.ReleaseNotes do
  @moduledoc """
  Releases' notes as `ehosctl changelog` and `ehosctl upgrade` print them. Apart from both, since
  `upgrade` is on the platform plane and `changelog` reaches the sign-in code (eh-os D-87).
  """

  alias Ehosctl.GitHub
  alias Ehosctl.Output

  @doc """
  Releases of `component` with their notes as `Ehosctl.GitHub.notes/2` read them, each under its
  version, its date and its page, in the order given: as `changelog` prints them.
  """
  @spec printed(GitHub.component(), [{GitHub.release(), {:ok, String.t()} | GitHub.error()}]) ::
          String.t()
  def printed(component, read) do
    Enum.map_join(read, "\n\n", fn {release, notes} ->
      published = if release.published_at, do: " (#{Output.date(release.published_at)})"

      heading = "# #{component} #{release.version}#{published}\n#{release.url}"

      body =
        case notes do
          {:ok, notes} -> shown(notes)
          {:error, _kind, message} -> "ehosctl cannot read the notes of this release. #{message}"
        end

      heading <> "\n\n" <> body
    end)
  end

  @doc """
  Releases of `component` with their notes, as `upgrade` prints them before its question: each
  under a line that names its version, its date and its page, its lines indented and dim on a
  terminal, so that they are not read as ehosctl's own (`Ehosctl.Output.tool_output/2`).
  """
  @spec framed(GitHub.component(), [{GitHub.release(), {:ok, String.t()} | GitHub.error()}]) ::
          Output.text()
  def framed(component, read) do
    read
    |> Enum.map(fn {release, notes} ->
      published = if release.published_at, do: ", #{Output.date(release.published_at)}"

      [
        "The notes of #{component} #{release.version}#{published}, at #{release.url}:"
        | framed_body(notes)
      ]
    end)
    |> Enum.intersperse("\n\n")
  end

  defp framed_body({:ok, notes}) do
    case String.trim(notes) do
      "" -> [" ", Output.none()]
      notes -> ["\n", Owl.Data.tag(indented(notes), :faint)]
    end
  end

  # ehosctl's own sentence: indented under the release, not dim as the notes are.
  defp framed_body({:error, _kind, message}),
    do: ["\n", indented("ehosctl cannot read the notes of this release. " <> to_string(message))]

  # Escaped line by line first, so that a line a terminal would act on is quoted at its indent;
  # the caller tags the whole as one, since notes may be 2 MiB and a tag for each line costs its
  # codes each time.
  defp indented(text) do
    text
    |> Output.shown_lines()
    |> String.split("\n")
    |> Enum.map_join("\n", &if(String.trim(&1) == "", do: "", else: "  " <> &1))
  end

  # Notes are Markdown written by people, printed as they are, but a line a terminal would act
  # on is printed quoted with its escapes.
  defp shown(notes), do: notes |> String.trim() |> Ehosctl.Output.shown_lines()
end
