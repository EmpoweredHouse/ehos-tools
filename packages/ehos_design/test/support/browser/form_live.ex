defmodule EhosDesign.Browser.FormLive do
  @moduledoc false
  # A form as a host writes one: a picker and a combobox in a form with `phx-change`, the state
  # kept here and passed back, and what was submitted shown, so a test can see that Enter in the
  # combobox submitted nothing.

  use Phoenix.LiveView

  import EhosDesign.Components

  @roles [
    {"Appunite equipment",
     [
       %{value: "manager", title: "Equipment manager", subtitle: "Hands out equipment"},
       %{value: "auditor", title: "Auditor", subtitle: "Reads the record", disabled: true},
       %{value: "viewer", title: "Equipment viewer", subtitle: "Sees who holds what"}
     ]},
    {"Platform", [%{value: "operator", title: "Operator", subtitle: "Runs the platform"}]}
  ]

  @people [
    %{value: "p1", title: "Anna Kowalska", subtitle: "anna@example.com"},
    %{value: "p2", title: "Annette Berg", subtitle: "annette@example.com"},
    %{value: "p3", title: "Bruno Diaz", subtitle: "bruno@example.com"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, role: nil, person: nil, query: "", submitted: 0, roles: @roles)}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :found, found(assigns.query))

    ~H"""
    <h1 id="title" style="color: var(--text-primary)">The listbox</h1>
    <form id="form" phx-change="change" phx-submit="submit">
      <.picker id="role" name="f[role]" label="Role" options={@roles} value={@role} />
      <.combobox
        id="person"
        name="f[person]"
        query_name="q"
        label="Person"
        query={@query}
        options={@found}
        value={@person}
        message={@found == [] && "No one's name begins with that."}
      />
      <input id="note" type="text" name="note" />
      <button id="submit" type="submit">Save</button>
    </form>
    <p id="state" data-role={@role} data-person={@person} data-submitted={@submitted}>
      Submitted {@submitted} times
    </p>
    """
  end

  @impl true
  def handle_event("change", params, socket) do
    form = params["f"] || %{}
    person = blank(form["person"])

    query =
      case params["_target"] do
        ["f", "person"] -> title(person) || params["q"] || ""
        _other -> params["q"] || ""
      end

    {:noreply, assign(socket, role: blank(form["role"]), person: person, query: query)}
  end

  def handle_event("submit", _params, socket) do
    {:noreply, update(socket, :submitted, &(&1 + 1))}
  end

  defp found(query) do
    query = String.downcase(query)
    Enum.filter(@people, &String.starts_with?(String.downcase(&1.title), query))
  end

  defp title(nil), do: nil
  defp title(value), do: Enum.find_value(@people, &(&1.value == value && &1.title))

  defp blank(value) when value in [nil, ""], do: nil
  defp blank(value), do: value
end
