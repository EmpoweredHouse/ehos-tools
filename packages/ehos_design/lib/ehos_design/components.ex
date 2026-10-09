defmodule EhosDesign.Components do
  @moduledoc """
  The design system's application components, as function components for Phoenix LiveView
  (eh-os D-86). Their look is the design system's: each renders the classes of a stylesheet
  copied from its source into `priv/css/components/`, which `priv/css/ehos_design.css` imports.
  Their behaviour is here.

  ## The listbox

  Two controls choose one item from a list, each item a title and an optional subtitle:

    * `picker/1`, a button that opens the list of what is offered, the WAI-ARIA Authoring
      Practices' *select-only combobox*;
    * `combobox/1`, a text field whose list shows what the host found for what is typed, their
      *editable combobox with list autocomplete*.

  Both keep the focus on the control and name the option the keyboard is on with
  `aria-activedescendant`. The keys follow the Authoring Practices, except that Tab closes the
  list without choosing, and there is no type-ahead:

  | Key | Picker | Combobox |
  | --- | --- | --- |
  | ↓ / ↑ | Opens the list; then the next or previous option | The same |
  | Home / End | The first or last option | Left to the text field |
  | Enter | Opens the list; then chooses | Chooses, and never submits the form |
  | Space | Opens the list; then chooses | Left to the text field |
  | Escape | Closes the list | Closes the list; when closed, clears the field |
  | Tab | Closes the list | The same |

  A choice sets a hidden input, `name`, to the option's value, and dispatches `input` on it, so
  the host learns of it through its form's `phx-change`, as of any other field. The host keeps
  the state: what is offered, what is chosen, what was searched for. It passes back what its form
  holds, as it does for any input, or the next render undoes the choice.

  ## The outcome

  `outcome/1` says how something ended, in a card with a mark, a title, one sentence and a hint:
  what a page shows when it has nothing else to show.

  ## Using them

  Import the module where the host's components are available, such as `html_helpers` in
  `lib/my_app_web.ex`, and add the hook to the host's `LiveSocket` in `assets/js/app.js`:

  ```js
  import {hooks as designHooks} from "phoenix-colocated/ehos_design"

  const liveSocket = new LiveSocket("/live", Socket, {
    hooks: {...colocatedHooks, ...designHooks},
    // …
  })
  ```

  An option is a map with `:value` and `:title`, and optionally `:subtitle` and `:disabled`. A
  list of options may be grouped instead, as `[{"Group label", [option, …]}, …]`. Every option is
  rendered and diffed on each change, so a host that searches keeps its results to a page, as
  `/api/people` does.

  Errors are the host's to translate, as `<.input>`'s are: pass them as `errors`, such as
  `errors={Enum.map(@form[:role].errors, &translate_error/1)}`.
  """

  use Phoenix.Component

  @typedoc "An item to choose."
  @type option :: %{
          required(:value) => String.t(),
          required(:title) => String.t(),
          optional(:subtitle) => String.t() | nil,
          optional(:disabled) => boolean()
        }

  @doc """
  A button that opens a list to choose one option from: the select-only combobox.

  The chosen option is shown in the button, its title over its subtitle, and sent as `name`.

  ## Example

      <.picker
        id="role"
        name="binding[role]"
        label="Role"
        value={@role}
        options={[{"Platform", [%{value: "operator", title: "Operator", subtitle: "Runs it"}]}]}
      />
  """
  attr :id, :string, doc: "the component's id; the field's when `field` is given"
  attr :name, :string, doc: "the hidden input's name; the field's when `field` is given"
  attr :value, :any, default: nil, doc: "the chosen option's value"

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field, for its id, name and value, as `<.input>` takes one"

  attr :label, :string, required: true
  attr :options, :list, required: true, doc: "options, or `{label, options}` groups"
  attr :placeholder, :string, default: "Choose"
  attr :disabled, :boolean, default: false
  attr :errors, :list, default: [], doc: "what is wrong with the choice, translated"
  attr :class, :any, default: "fieldset mb-2", doc: "the wrapper's classes"

  def picker(assigns) do
    assigns = assigns |> from_field() |> assign_groups()
    assigns = assign(assigns, :chosen, chosen(assigns.groups, assigns.value))

    ~H"""
    <div id={@id} class={@class} phx-hook=".Listbox" data-kind="picker">
      <span id={"#{@id}-label"} class="label mb-1">{@label}</span>
      <div class="eh-listbox-anchor">
        <button
          type="button"
          id={"#{@id}-control"}
          class="eh-picker"
          role="combobox"
          aria-haspopup="listbox"
          aria-expanded="false"
          aria-controls={"#{@id}-listbox"}
          aria-labelledby={"#{@id}-label #{@id}-control"}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={@errors != [] && "#{@id}-errors"}
          disabled={@disabled}
        >
          <%= if @chosen do %>
            <span class="eh-picker-value">{@chosen.title}</span>
            <span :if={@chosen[:subtitle]} class="eh-picker-detail">{@chosen.subtitle}</span>
          <% else %>
            <span class="eh-picker-placeholder">{@placeholder}</span>
          <% end %>
        </button>
        <.listbox id={@id} groups={@groups} value={@value} />
      </div>
      <%!-- Only what is offered is sent: a value the options no longer hold is shown as nothing chosen, and sent as nothing. --%>
      <input
        type="hidden"
        id={"#{@id}-value"}
        name={@name}
        value={@chosen && @chosen.value}
        data-value
      />
      <.errors id={@id} errors={@errors} />
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Listbox">
      // eh-os D-86: one hook for both controls, after the WAI-ARIA Authoring Practices'
      // combobox patterns. The focus stays on the control; the option the keyboard is on is
      // marked `data-active` and named by `aria-activedescendant`. A render from the server
      // resets what this hook set, so `updated` sets it again.
      export default {
        mounted() {
          this.kind = this.el.dataset.kind
          this.isOpen = false
          this.activeValue = null

          this.el.addEventListener("keydown", (e) => {
            if (e.target === this.control()) this.keydown(e)
          })
          this.el.addEventListener("click", (e) => this.click(e))
          // A press anywhere in the list keeps the focus on the control.
          this.el.addEventListener("mousedown", (e) => {
            if (e.target.closest("[data-popup]")) e.preventDefault()
          })
          this.el.addEventListener("input", (e) => {
            if (this.kind === "combobox" && e.target === this.control()) this.typed()
          })
          this.el.addEventListener("focusin", (e) => {
            if (this.kind === "combobox" && e.target === this.control()) this.open()
          })
          this.el.addEventListener("focusout", (e) => {
            if (!this.el.contains(e.relatedTarget)) this.close()
          })
          this.outside = (e) => {
            if (!this.el.contains(e.target)) this.close()
          }
          document.addEventListener("click", this.outside)
        },

        updated() {
          const active = this.find(this.activeValue)
          this.activeValue = active ? this.activeValue : null
          if (this.isOpen) this.open()
          this.mark(active)
        },

        destroyed() {
          document.removeEventListener("click", this.outside)
        },

        control() { return this.el.querySelector("[role=combobox]") },
        hidden() { return this.el.querySelector("input[data-value]") },
        popups() { return [...this.el.querySelectorAll("[data-popup]")] },
        options() {
          return [...this.el.querySelectorAll("[role=option]")]
            .filter((o) => o.getAttribute("aria-disabled") !== "true")
        },
        find(value) {
          if (value === null) return null
          return this.options().find((o) => o.dataset.value === value) || null
        },

        open() {
          const shown = this.popups().filter((p) => p.dataset.popup === "message" ||
            p.querySelector("[role=option]"))
          this.popups().forEach((p) => { p.hidden = !shown.includes(p) })
          this.isOpen = true
          // Expanded names the listbox: a message alone is a status, not a list.
          const listbox = shown.find((p) => p.dataset.popup === "listbox")
          this.control().setAttribute("aria-expanded", String(Boolean(listbox)))
        },

        close() {
          this.popups().forEach((p) => { p.hidden = true })
          this.isOpen = false
          this.control().setAttribute("aria-expanded", "false")
          this.mark(null)
        },

        mark(option) {
          this.el.querySelectorAll("[role=option][data-active]")
            .forEach((o) => o.removeAttribute("data-active"))
          this.activeValue = option ? option.dataset.value : null
          if (option && this.isOpen) {
            option.setAttribute("data-active", "")
            this.control().setAttribute("aria-activedescendant", option.id)
            option.scrollIntoView({block: "nearest"})
          } else {
            this.control().removeAttribute("aria-activedescendant")
          }
        },

        // Opens the list, on the chosen option or else the first or last one.
        openOn(edge) {
          this.open()
          const options = this.options()
          const chosen = this.find(this.hidden().value)
          this.mark(chosen || (edge === "last" ? options[options.length - 1] : options[0]) || null)
        },

        move(step) {
          const options = this.options()
          if (options.length === 0) return
          const at = options.findIndex((o) => o.dataset.value === this.activeValue)
          const next = at === -1 ? (step > 0 ? 0 : options.length - 1)
            : Math.min(Math.max(at + step, 0), options.length - 1)
          this.mark(options[next])
        },

        keydown(e) {
          // A key that ends an input method's composition belongs to the composition. Safari
          // ends the composition first, and marks the key with keyCode 229 instead.
          if (e.isComposing || e.keyCode === 229) return
          // Open is what shows: a list opened over nothing to show is closed to the keys.
          const open = this.isOpen && this.popups().some((p) => !p.hidden)
          const picker = this.kind === "picker"

          switch (e.key) {
            case "ArrowDown":
            case "ArrowUp":
              e.preventDefault()
              if (!open) {
                if (e.altKey) this.open()
                else this.openOn(e.key === "ArrowUp" && !picker ? "last" : "first")
              } else if (e.altKey && e.key === "ArrowUp") {
                this.close()
              } else {
                this.move(e.key === "ArrowDown" ? 1 : -1)
              }
              return
            case "Home":
            case "End": {
              if (!picker) return
              e.preventDefault()
              if (!open) this.open()
              const options = this.options()
              this.mark(e.key === "Home" ? options[0] : options[options.length - 1])
              return
            }
            case "Enter":
            case " ":
              if (e.key === " " && !picker) return
              // A combobox's field is a search, never a value of the form: Enter never submits.
              e.preventDefault()
              if (open && this.activeValue !== null) this.choose(this.find(this.activeValue))
              else if (picker) this.openOn("first")
              return
            case "Escape":
              if (open) {
                e.preventDefault()
                this.close()
              } else if (!picker && this.control().value !== "") {
                e.preventDefault()
                this.control().value = ""
                this.control().dispatchEvent(new Event("input", {bubbles: true}))
                // Clearing is not searching: the list stays closed.
                this.close()
              }
              return
            case "Tab":
              this.close()
              return
          }
        },

        click(e) {
          const option = e.target.closest("[role=option]")
          if (option) {
            if (option.getAttribute("aria-disabled") !== "true") this.choose(option)
            return
          }
          // A click a key made (`detail` 0) is handled by `keydown`.
          if (this.kind === "picker" && e.target.closest("[role=combobox]") && e.detail > 0) {
            // Safari, and Firefox on macOS, do not focus a button that is clicked.
            this.control().focus()
            this.isOpen ? this.close() : this.openOn("first")
          }
        },

        // Typing again is looking for something else: the choice so far is dropped.
        typed() {
          this.hidden().value = ""
          this.el.querySelectorAll("[role=option]")
            .forEach((o) => o.setAttribute("aria-selected", "false"))
          this.open()
          this.mark(null)
        },

        choose(option) {
          if (!option) return
          const hidden = this.hidden()
          hidden.value = option.dataset.value
          this.el.querySelectorAll("[role=option]")
            .forEach((o) => o.setAttribute("aria-selected", String(o === option)))
          this.show(option)
          this.close()
          hidden.dispatchEvent(new Event("input", {bubbles: true}))
        },

        // What the control shows until the server renders it.
        show(option) {
          const title = option.querySelector(".eh-option-title")
          const subtitle = option.querySelector(".eh-option-subtitle")
          if (this.kind === "combobox") {
            this.control().value = title ? title.textContent : ""
            return
          }
          const control = this.control()
          control.replaceChildren()
          for (const [source, name] of [[title, "eh-picker-value"], [subtitle, "eh-picker-detail"]]) {
            if (!source) continue
            const span = document.createElement("span")
            span.className = name
            span.textContent = source.textContent
            control.append(span)
          }
        },
      }
    </script>
    """
  end

  @doc """
  A text field whose list shows what the host found for what is typed: the editable combobox
  with list autocomplete.

  The field is a search, sent as `query_name` with the form's `phx-change`, and never a value
  of the form: the chosen option is sent as `name`, and Enter never submits. Typing again drops
  the choice. When the list is empty, `message` says why, in the error colour when
  `message_kind` is `:error`.

  ## Example

      <.combobox
        id="person"
        name="f[employee]"
        query_name="people[employee]"
        label="Person"
        query={@picker.q}
        value={@picker.selected}
        options={for {name, id} <- @picker.options, do: %{value: id, title: name}}
        message={@picker.message}
      />
  """
  attr :id, :string, doc: "the component's id; the field's when `field` is given"
  attr :name, :string, doc: "the hidden input's name; the field's when `field` is given"
  attr :value, :any, default: nil, doc: "the chosen option's value"

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field, for its id, name and value, as `<.input>` takes one"

  attr :label, :string, required: true
  attr :query_name, :string, required: true, doc: "the text field's name"
  attr :query, :string, default: "", doc: "what the text field holds"
  attr :options, :list, required: true, doc: "what was found, or `{label, options}` groups"
  attr :message, :string, default: nil, doc: "why the list is empty, shown in its place"
  attr :message_kind, :atom, values: [:info, :error], default: :info
  attr :placeholder, :string, default: nil
  attr :debounce, :string, default: "300", doc: "the text field's `phx-debounce`"
  attr :disabled, :boolean, default: false
  attr :errors, :list, default: [], doc: "what is wrong with the choice, translated"
  attr :class, :any, default: "fieldset mb-2", doc: "the wrapper's classes"

  def combobox(assigns) do
    assigns = assigns |> from_field() |> assign_groups()

    ~H"""
    <div id={@id} class={@class} phx-hook=".Listbox" data-kind="combobox">
      <label id={"#{@id}-label"} for={"#{@id}-control"} class="label mb-1">{@label}</label>
      <div class="eh-listbox-anchor">
        <input
          type="text"
          id={"#{@id}-control"}
          class="eh-combobox"
          role="combobox"
          aria-autocomplete="list"
          aria-expanded="false"
          aria-controls={"#{@id}-listbox"}
          autocomplete="off"
          name={@query_name}
          value={@query}
          placeholder={@placeholder}
          disabled={@disabled}
          phx-debounce={@debounce}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={@errors != [] && "#{@id}-errors"}
        />
        <.listbox id={@id} groups={@groups} value={@value} />
        <div
          :if={@groups == [] and @message}
          id={"#{@id}-message"}
          class="eh-listbox"
          data-popup="message"
          hidden
        >
          <div class="eh-listbox-message" data-kind={@message_kind} role="status">{@message}</div>
        </div>
      </div>
      <input type="hidden" id={"#{@id}-value"} name={@name} value={@value} data-value />
      <.errors id={@id} errors={@errors} />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :errors, :list, required: true

  defp errors(assigns) do
    ~H"""
    <div :if={@errors != []} id={"#{@id}-errors"}>
      <p :for={error <- @errors} class="mt-1.5 text-sm text-error-ink">{error}</p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :groups, :list, required: true
  attr :value, :any, required: true

  defp listbox(assigns) do
    ~H"""
    <div
      id={"#{@id}-listbox"}
      class="eh-listbox"
      role="listbox"
      aria-labelledby={"#{@id}-label"}
      data-popup="listbox"
      hidden
    >
      <%= for {{label, options}, g} <- Enum.with_index(@groups) do %>
        <%= if label do %>
          <div class="eh-listbox-group" role="group" aria-labelledby={"#{@id}-group-#{g}"}>
            <span id={"#{@id}-group-#{g}"} class="eh-listbox-group-label">{label}</span>
            <.option
              :for={{option, o} <- Enum.with_index(options)}
              id={"#{@id}-option-#{g}-#{o}"}
              option={option}
              value={@value}
            />
          </div>
        <% else %>
          <.option
            :for={{option, o} <- Enum.with_index(options)}
            id={"#{@id}-option-#{g}-#{o}"}
            option={option}
            value={@value}
          />
        <% end %>
      <% end %>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :option, :map, required: true
  attr :value, :any, required: true

  defp option(assigns) do
    ~H"""
    <div
      id={@id}
      class="eh-option"
      role="option"
      data-value={@option.value}
      aria-selected={to_string(chosen?(@option, @value))}
      aria-disabled={@option[:disabled] && "true"}
    >
      <span class="eh-option-title">{@option.title}</span>
      <span :if={@option[:subtitle]} class="eh-option-subtitle" title={@option.subtitle}>
        {@option.subtitle}
      </span>
    </div>
    """
  end

  defp from_field(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns
    |> assign_new(:id, fn -> field.id end)
    |> assign_new(:name, fn -> field.name end)
    |> assign(:value, assigns[:value] || field.value)
  end

  defp from_field(%{id: _id, name: _name} = assigns), do: assigns

  defp from_field(_assigns) do
    raise ArgumentError, "a picker or a combobox needs either `field`, or both `id` and `name`"
  end

  # Options as groups, each `{label, options}`, the label `nil` for options not in a group.
  defp assign_groups(assigns) do
    groups =
      assigns.options
      |> Enum.chunk_by(&match?({_label, _options}, &1))
      |> Enum.flat_map(fn
        [{_label, _options} | _] = groups -> groups
        options -> [{nil, options}]
      end)
      |> Enum.reject(fn {_label, options} -> options == [] end)

    assign(assigns, :groups, groups)
  end

  defp chosen(groups, value) do
    Enum.find_value(groups, fn {_label, options} ->
      Enum.find(options, &chosen?(&1, value))
    end)
  end

  defp chosen?(_option, value) when value in [nil, ""], do: false
  defp chosen?(option, value), do: to_string(option.value) == to_string(value)

  @doc """
  How something ended, said once: a card with a mark (a lime check, or a coral cross for
  `kind={:error}`), a title, one sentence and an optional hint on what to do next. It is what a
  page shows when it has nothing else to show, such as a link that was used or an action that is
  done. Its look is `components/outcome.css`.

  ## Example

      <.outcome title="Link used" hint="You can close this tab.">
        You are signed in to the console.
      </.outcome>
  """
  attr :kind, :atom, values: [:ok, :error], default: :ok
  attr :title, :string, required: true
  attr :hint, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true, doc: "the sentence"

  def outcome(assigns) do
    ~H"""
    <div class="eh-outcome" data-kind={@kind == :error && "error"} role="status" {@rest}>
      <span class="eh-outcome-mark" aria-hidden="true"></span>
      <h2 class="eh-outcome-title">{@title}</h2>
      <p class="eh-outcome-text">{render_slot(@inner_block)}</p>
      <p :if={@hint} class="eh-outcome-hint">{@hint}</p>
    </div>
    """
  end
end
