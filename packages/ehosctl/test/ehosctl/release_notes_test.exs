defmodule Ehosctl.ReleaseNotesTest do
  use ExUnit.Case, async: true

  alias Ehosctl.Output
  alias Ehosctl.ReleaseNotes

  @release %{
    version: "0.7.0",
    url: "https://github.com/EmpoweredHouse/eh-os/releases/tag/v0.7.0",
    published_at: "2026-10-09T12:00:00Z"
  }

  describe "framed/2" do
    test "dims the notes as one span at a terminal, and leaves ehosctl's own sentence plain" do
      framed =
        ReleaseNotes.framed("ehos", [
          {@release, {:ok, "## Fixed\n- A fix."}},
          {%{@release | version: "0.6.0"},
           {:error, :failed, "GitHub did not answer.\nTry again."}}
        ])

      assert framed |> Output.render(true) |> IO.chardata_to_string() ==
               "The notes of ehos 0.7.0, 9 October 2026, 12:00 UTC, at " <>
                 "https://github.com/EmpoweredHouse/eh-os/releases/tag/v0.7.0:\n" <>
                 "\e[2m  ## Fixed\n  - A fix.\e[0m\n\n" <>
                 "The notes of ehos 0.6.0, 9 October 2026, 12:00 UTC, at " <>
                 "https://github.com/EmpoweredHouse/eh-os/releases/tag/v0.7.0:\n" <>
                 "  ehosctl cannot read the notes of this release. GitHub did not answer.\n" <>
                 "  Try again."
    end
  end
end
