defmodule Ehosctl.RefusalTest do
  use ExUnit.Case, async: true

  alias Ehosctl.Refusal

  doctest Ehosctl.Refusal

  test "an account that may not use EHOS's console is refused, in EHOS's words, at any status" do
    message = "Your account opens its applications, not EHOS itself."
    body = %{"error" => "no_console", "message" => message}

    assert Refusal.kind("no_console") == :refused
    assert Refusal.ehos(%{status: 400, body: body}, "EHOS") == {:error, :refused, message}
  end
end
