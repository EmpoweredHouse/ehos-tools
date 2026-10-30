defmodule EhosDiagrams.EhOsTest do
  @moduledoc """
  T-21's proof: eh-os's ten diagrams, rendered here with eh-os's vocabulary, are byte for byte
  the outputs eh-os committed. `test/fixtures/eh-os/README.md` says which commit they come from
  and how they were taken.
  """

  use ExUnit.Case, async: true

  @fixtures "test/fixtures/eh-os"

  # eh-os D-106's badges, from most to least real, with D-107's outlines.
  @badges [
    {"built", :none},
    {"building", :solid},
    {"decided", :solid},
    {"planned", :dashed},
    {"idea", :dotted},
    {"open", :muted}
  ]

  test "eh-os's ten diagrams come out byte for byte as eh-os committed them" do
    design = EhosDiagrams.design("../ehos_design/priv")
    committed = committed()

    rendered =
      for source <- Path.wildcard(Path.join(@fixtures, "diagrams/*.svg")), into: %{} do
        id = Path.basename(source, ".svg")

        {:ok, svg} =
          EhosDiagrams.render(File.read!(source), id, design, vocabulary(),
            generator: "mix ehos.gen.diagrams",
            source: "docs/architecture/diagrams/#{id}.svg",
            record: "D-107"
          )

        {id <> ".svg", sha256(svg)}
      end

    assert map_size(rendered) == 10
    assert rendered == committed
  end

  defp vocabulary do
    json = @fixtures |> Path.join("vocabulary.json") |> File.read!() |> JSON.decode!()

    %{
      words: json["words"],
      alone: Enum.map(json["alone"], fn [word, phrases] -> {word, phrases} end),
      concepts: json["concepts"],
      badges: @badges
    }
  end

  defp committed do
    for line <-
          @fixtures |> Path.join("img.sha256") |> File.read!() |> String.split("\n", trim: true),
        [hash, file] = String.split(line, ~r/\s+/, parts: 2),
        into: %{},
        do: {file, hash}
  end

  defp sha256(svg), do: :sha256 |> :crypto.hash(svg) |> Base.encode16(case: :lower)
end
