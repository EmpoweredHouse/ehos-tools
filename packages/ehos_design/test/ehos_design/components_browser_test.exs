defmodule EhosDesign.ComponentsBrowserTest do
  # eh-os D-86: the keyboard, in a browser, on a page whose form keeps its state on the server
  # (`EhosDesign.Browser.FormLive`). Needs Playwright and its browser: `mix browser.setup`.
  use PhoenixTest.Playwright.Case, async: true

  # The hook mounts once LiveView has connected; a key pressed before then reaches no hook.
  defp connected(conn), do: conn |> visit("/") |> assert_has("[data-phx-main].phx-connected")

  defp state(conn, name, value), do: assert_has(conn, "#state[data-#{name}='#{value}']")

  defp active(conn, control, option),
    do:
      assert_has(
        conn,
        "##{control}[aria-activedescendant='#{option}'] ~ [role=listbox] ##{option}[data-active]"
      )

  defp open(conn, id),
    do: assert_has(conn, "##{id}-control[aria-expanded='true'] ~ ##{id}-listbox:not([hidden])")

  defp value(conn, selector, expected) do
    evaluate(conn, "document.querySelector(#{inspect(selector)}).value", &assert(&1 == expected))
  end

  # A closed list is hidden, and what is hidden is what `assert_has` never finds.
  defp closed(conn, id) do
    conn
    |> assert_has("##{id}-control[aria-expanded='false']")
    |> refute_has("##{id}-listbox:not([hidden])")
  end

  describe "the picker" do
    test "opens on ↓, moves past a disabled option, stops at the ends, and chooses with Enter",
         %{conn: conn} do
      conn
      |> connected()
      |> closed("role")
      |> press("#role-control", "ArrowDown")
      |> open("role")
      |> active("role-control", "role-option-0-0")
      # The auditor, second, cannot be chosen.
      |> press("#role-control", "ArrowDown")
      |> active("role-control", "role-option-0-2")
      |> press("#role-control", "ArrowDown")
      |> active("role-control", "role-option-1-0")
      |> press("#role-control", "ArrowDown")
      |> active("role-control", "role-option-1-0")
      |> press("#role-control", "Home")
      |> active("role-control", "role-option-0-0")
      |> press("#role-control", "End")
      |> active("role-control", "role-option-1-0")
      |> press("#role-control", "Enter")
      |> closed("role")
      |> state("role", "operator")
      |> assert_has("#role-control .eh-picker-value", text: "Operator")
      |> refute_has("#role-control[aria-activedescendant]")
    end

    test "opens on the chosen option, and Escape closes it without changing the choice",
         %{conn: conn} do
      conn
      |> connected()
      |> press("#role-control", "End")
      |> press("#role-control", "Enter")
      |> state("role", "operator")
      |> press("#role-control", "ArrowDown")
      |> assert_has("#role-option-1-0[aria-selected='true']")
      |> active("role-control", "role-option-1-0")
      |> press("#role-control", "ArrowUp")
      |> active("role-control", "role-option-0-2")
      |> press("#role-control", "Escape")
      |> closed("role")
      |> state("role", "operator")
      |> press("#role-control", "Enter")
      |> open("role")
      |> press("#role-control", "Tab")
      |> closed("role")
    end

    test "opens and chooses with the pointer, and closes on a click above it", %{conn: conn} do
      conn
      |> connected()
      |> click("#role-control")
      |> open("role")
      |> click("#role-option-0-2")
      |> closed("role")
      |> state("role", "viewer")
      |> click("#role-control")
      |> open("role")
      |> click("#title")
      |> closed("role")
    end
  end

  describe "the combobox" do
    test "lists what was found, moves with the arrows, and chooses with Enter without submitting",
         %{conn: conn} do
      conn
      |> connected()
      |> type("#person-control", "ann")
      |> assert_has("#person-listbox:not([hidden]) [role=option]", count: 2)
      |> assert_has("#person-control[aria-expanded='true']")
      |> refute_has("#person-control[aria-activedescendant]")
      |> press("#person-control", "ArrowDown")
      |> active("person-control", "person-option-0-0")
      |> press("#person-control", "ArrowDown")
      |> active("person-control", "person-option-0-1")
      |> press("#person-control", "Enter")
      |> closed("person")
      |> state("person", "p2")
      |> value("#person-control", "Annette Berg")
      |> press("#person-control", "Enter")
      |> state("submitted", "0")
      |> click("#submit")
      |> state("submitted", "1")
    end

    test "drops the choice when typed into again, and clears with a second Escape",
         %{conn: conn} do
      conn
      |> connected()
      |> type("#person-control", "bru")
      |> assert_has("#person-listbox [role=option]", count: 1)
      |> press("#person-control", "ArrowDown")
      |> press("#person-control", "Enter")
      |> state("person", "p3")
      |> type("#person-control", "n")
      |> refute_has("#state[data-person]")
      |> press("#person-control", "Escape")
      |> closed("person")
      |> press("#person-control", "Escape")
      |> value("#person-control", "")
    end

    test "says why its list is empty", %{conn: conn} do
      conn
      |> connected()
      |> type("#person-control", "zz")
      |> assert_has("#person-message:not([hidden]) [role=status]", text: "No one's name")
      |> assert_has("#person-control[aria-expanded='true']")
    end
  end
end
