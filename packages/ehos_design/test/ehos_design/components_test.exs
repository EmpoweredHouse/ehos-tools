defmodule EhosDesign.ComponentsTest do
  # eh-os D-86: the components render the roles and states of the WAI-ARIA combobox patterns, on
  # the classes of the stylesheet copied from the design system's source.
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import EhosDesign.Components

  @stylesheet Path.expand("../../priv/css/components/listbox.css", __DIR__)

  @roles [
    {"Appunite equipment",
     [
       %{value: "manager", title: "Equipment manager", subtitle: "Hands out equipment"},
       %{value: "viewer", title: "Equipment viewer"}
     ]},
    {"Platform", [%{value: "operator", title: "Operator", disabled: true}]}
  ]

  defp render(template), do: template |> rendered_to_string() |> LazyHTML.from_fragment()

  defp attribute(html, selector, name),
    do: html |> LazyHTML.query(selector) |> LazyHTML.attribute(name)

  defp text(html, selector),
    do: html |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

  defp picker_with(assigns) do
    assigns = Map.merge(%{options: @roles, value: nil}, assigns)

    render(~H"""
    <.picker id="role" name="binding[role]" label="Role" options={@options} value={@value} />
    """)
  end

  describe "picker/1" do
    test "is a button with the combobox role, which controls a listbox labelled as it is" do
      html = picker_with(%{})

      assert attribute(html, "#role", "phx-hook") == ["EhosDesign.Components.Listbox"]
      assert attribute(html, "#role", "data-kind") == ["picker"]
      assert attribute(html, "button#role-control", "role") == ["combobox"]
      assert attribute(html, "#role-control", "type") == ["button"]
      assert attribute(html, "#role-control", "aria-haspopup") == ["listbox"]
      assert attribute(html, "#role-control", "aria-expanded") == ["false"]
      assert attribute(html, "#role-control", "aria-controls") == ["role-listbox"]
      assert attribute(html, "#role-control", "aria-labelledby") == ["role-label role-control"]
      assert attribute(html, "#role-listbox", "role") == ["listbox"]
      assert attribute(html, "#role-listbox", "aria-labelledby") == ["role-label"]
      assert attribute(html, "#role-listbox", "hidden") == [""]
      assert text(html, "#role-label") == "Role"
    end

    test "groups its options under labelled groups, each option with an id the hook can name" do
      html = picker_with(%{})

      assert attribute(html, "[role=group]", "aria-labelledby") == [
               "role-group-0",
               "role-group-1"
             ]

      assert text(html, "#role-group-0") == "Appunite equipment"

      assert attribute(html, "[role=option]", "id") ==
               ["role-option-0-0", "role-option-0-1", "role-option-1-0"]

      assert attribute(html, "[role=option]", "data-value") == ["manager", "viewer", "operator"]
      assert text(html, "#role-option-0-0 .eh-option-subtitle") == "Hands out equipment"
      assert attribute(html, "#role-option-0-1 .eh-option-subtitle", "class") == []
      assert attribute(html, "#role-option-1-0", "aria-disabled") == ["true"]
      assert attribute(html, "#role-option-0-0", "aria-disabled") == []
    end

    test "shows the placeholder and sends nothing while nothing is chosen" do
      html = picker_with(%{})

      assert text(html, "#role-control .eh-picker-placeholder") == "Choose"
      assert attribute(html, "[role=option]", "aria-selected") == ["false", "false", "false"]
      assert attribute(html, "input#role-value", "name") == ["binding[role]"]
      assert attribute(html, "#role-value", "type") == ["hidden"]
      assert attribute(html, "#role-value", "value") == []
    end

    test "shows the chosen option in the button, marks it selected and sends its value" do
      html = picker_with(%{value: "manager"})

      assert text(html, "#role-control .eh-picker-value") == "Equipment manager"
      assert text(html, "#role-control .eh-picker-detail") == "Hands out equipment"
      assert attribute(html, "[role=option]", "aria-selected") == ["true", "false", "false"]
      assert attribute(html, "#role-value", "value") == ["manager"]
    end

    test "takes options without groups" do
      html = picker_with(%{options: [%{value: "a", title: "A"}, %{value: "b", title: "B"}]})

      assert attribute(html, "[role=group]", "role") == []
      assert attribute(html, "[role=option]", "id") == ["role-option-0-0", "role-option-0-1"]
    end

    test "takes its id, name and value from a form field" do
      form = Phoenix.Component.to_form(%{"role" => "viewer"}, as: :binding)
      assigns = %{form: form, options: @roles}

      html =
        render(~H"""
        <.picker field={@form[:role]} label="Role" options={@options} />
        """)

      assert attribute(html, "#binding_role-value", "name") == ["binding[role]"]
      assert attribute(html, "#binding_role-value", "value") == ["viewer"]
      assert text(html, "#binding_role-control .eh-picker-value") == "Equipment viewer"
    end
  end

  defp combobox_with(assigns) do
    assigns = Map.merge(%{options: [], value: nil, message: nil, kind: :info}, assigns)

    render(~H"""
    <.combobox
      id="person"
      name="f[employee]"
      query_name="people[employee]"
      label="Person"
      query="ann"
      options={@options}
      value={@value}
      message={@message}
      message_kind={@kind}
    />
    """)
  end

  describe "combobox/1" do
    @people [
      %{value: "p1", title: "Anna Kowalska", subtitle: "anna@example.com"},
      %{value: "p2", title: "Annette Berg"}
    ]

    test "is a text field with the combobox role and list autocomplete, sent as the search" do
      html = combobox_with(%{options: @people})

      assert attribute(html, "#person", "data-kind") == ["combobox"]
      assert attribute(html, "input#person-control", "role") == ["combobox"]
      assert attribute(html, "#person-control", "type") == ["text"]
      assert attribute(html, "#person-control", "aria-autocomplete") == ["list"]
      assert attribute(html, "#person-control", "aria-expanded") == ["false"]
      assert attribute(html, "#person-control", "aria-controls") == ["person-listbox"]
      assert attribute(html, "#person-control", "autocomplete") == ["off"]
      assert attribute(html, "#person-control", "name") == ["people[employee]"]
      assert attribute(html, "#person-control", "value") == ["ann"]
      assert attribute(html, "#person-control", "phx-debounce") == ["300"]
      assert attribute(html, "label#person-label", "for") == ["person-control"]
      assert attribute(html, "#person-listbox [role=option]", "data-value") == ["p1", "p2"]
    end

    test "sends the chosen option's value in a hidden input of its own" do
      html = combobox_with(%{options: @people, value: "p2"})

      assert attribute(html, "input#person-value", "type") == ["hidden"]
      assert attribute(html, "#person-value", "name") == ["f[employee]"]
      assert attribute(html, "#person-value", "value") == ["p2"]
      assert attribute(html, "[role=option]", "aria-selected") == ["false", "true"]
    end

    test "says why its list is empty, in the error colour when the search failed" do
      html = combobox_with(%{message: "EHOS cannot be reached.", kind: :error})

      assert attribute(html, "#person-listbox [role=option]", "id") == []
      assert attribute(html, "#person-message", "data-popup") == ["message"]
      assert attribute(html, "#person-message", "hidden") == [""]
      assert attribute(html, "#person-message .eh-listbox-message", "role") == ["status"]
      assert attribute(html, "#person-message .eh-listbox-message", "data-kind") == ["error"]
      assert text(html, "#person-message") == "EHOS cannot be reached."
    end

    test "shows no message beside options" do
      html = combobox_with(%{options: @people, message: "No one found."})

      assert attribute(html, "#person-message", "id") == []
    end
  end

  test "every class the components render is one the design system's stylesheet defines" do
    defined =
      ~r/\.(eh-[a-z-]+)/
      |> Regex.scan(File.read!(@stylesheet), capture: :all_but_first)
      |> List.flatten()
      |> MapSet.new()

    assigns = %{roles: @roles, people: @people}

    html =
      rendered_to_string(~H"""
      <.picker id="role" name="r" label="Role" options={@roles} value="manager" />
      <.picker id="none" name="n" label="None" options={@roles} />
      <.combobox id="p" name="p" query_name="q" label="Person" options={@people} />
      <.combobox id="m" name="m" query_name="q" label="Person" options={[]} message="None" />
      """)

    used =
      ~r/class="([^"]*)"/
      |> Regex.scan(html, capture: :all_but_first)
      |> List.flatten()
      |> Enum.flat_map(&String.split/1)
      |> Enum.filter(&String.starts_with?(&1, "eh-"))
      |> MapSet.new()

    assert MapSet.size(used) >= 10
    assert MapSet.difference(used, defined) |> Enum.sort() == []
  end
end
