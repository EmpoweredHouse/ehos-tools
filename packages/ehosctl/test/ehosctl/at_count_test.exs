defmodule Ehosctl.AtCountTest do
  use ExUnit.Case, async: true

  alias Ehosctl.AtCount

  doctest AtCount

  test "keeps at most 20 environments, as EHOS lists them, and counts the rest in more" do
    environments =
      for n <- 1..25,
          do: %{
            "name" => "ledger-#{n}",
            "application" => "ledger",
            "expires_at" => nil,
            "build" => nil
          }

    held = AtCount.held(%{"cap" => 3, "environments" => environments, "more" => 2})

    assert held == %{"cap" => 3, "environments" => Enum.take(environments, 20), "more" => 7}
  end
end
