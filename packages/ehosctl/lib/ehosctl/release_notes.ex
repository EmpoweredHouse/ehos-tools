defmodule Ehosctl.ReleaseNotes do
  @moduledoc """
  Releases' notes as `ehosctl changelog` and `ehosctl upgrade` print them. Apart from both, since
  `upgrade` is on the platform plane and `changelog` reaches the sign-in code (eh-os D-87).
  """

  alias Ehosctl.GitHub
  alias Ehosctl.Refusal

  @doc """
  Releases of `component` with their notes as `Ehosctl.GitHub.notes/2` read them, each under its
  version, its date and its page, in the order given: as `changelog` and `upgrade` print them.
  """
  @spec printed(GitHub.component(), [{GitHub.release(), {:ok, String.t()} | GitHub.error()}]) ::
          String.t()
  def printed(component, read) do
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
end
