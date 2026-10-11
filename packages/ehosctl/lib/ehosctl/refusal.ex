defmodule Ehosctl.Refusal do
  @moduledoc """
  A refusal from EHOS's API or from an application, as an error of a kind with its exit code, in
  the words of eh-os's
  [`docs/refusals.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/refusals.md).

  EHOS's API says its refusals itself, `{"error": <code>, "message": <sentence>}`, and its sentence
  is printed. An application built on `eh_os_contract` answers with a code alone
  (`EhOsContract.Plug`, `EhOsContract.Auth.Plug`), and its sentence is this module's.

  refusals.md's kinds map to `Ehosctl.Output`'s: Not signed in and Not accepted are
  `:not_signed_in` (4), Refused is `:refused` (3), Invalid is `:invalid` (2), Unavailable is
  `:unreachable` (5), and Not found, Conflict and Gone are `:failed` (1).
  """

  alias Ehosctl.HTTP
  alias Ehosctl.Output

  @type error :: {:error, Output.kind(), String.t()}

  @not_signed_in ~w(missing no_credential expired signed_out no_actor
                    unknown_key bad_signature wrong_issuer wrong_audience malformed no_keys
                    disabled unknown_principal)
  @refused ~w(forbidden missing_capability outside_scope unscoped_grant no_capability no_role
              escalation beyond_owner beyond_inviter workload)
  @failed ~w(not_found unknown_audience unknown_scope not_created
             already_bound in_use joined person_disabled last_administrator self superseded
             changed conflict idempotency_key_reused subject_erased
             unbound database_kept name_taken name_too_long host_too_long object_taken
             schema_taken binding_moved already_set not_classified used not_in_force
             too_many_agents not_requested)
  @invalid ~w(invalid rejected invalid_image too_large across_the_line schema_too_long
              schema_too_long_elsewhere schema_reserved idempotency_key_required idempotency_key_invalid
              key_too_long body_is_not_a_json_object unreadable_body invalid_query_string
              correlation_id_is_not_a_uuid unknown_role platform_only needs_environment
              wrong_application)
  @unreachable ~w(cluster_refused being_removed not_mailed ehos_unavailable not_supplied too_many_calls
                  temporarily_unavailable)

  @doc """
  The kind of a refusal's code, or `nil` for a code refusals.md does not name.

      iex> Ehosctl.Refusal.kind("missing_capability")
      :refused

      iex> Ehosctl.Refusal.kind("expired")
      :not_signed_in
  """
  @spec kind(String.t()) :: Output.kind() | nil
  def kind(code) when code in @not_signed_in, do: :not_signed_in
  def kind(code) when code in @refused, do: :refused
  def kind(code) when code in @failed, do: :failed
  def kind(code) when code in @invalid, do: :invalid
  def kind(code) when code in @unreachable, do: :unreachable
  def kind(_code), do: nil

  @doc """
  What EHOS's API answered `status` with, when it is not a success: its refusal's sentence, of
  the kind of its code, else of its status. `where` names the installation in an error that has
  no sentence of its own.
  """
  @spec ehos(HTTP.answer(), String.t()) :: error()
  def ehos(%{status: status, body: body}, where) do
    code = code(body)
    kind = (code && kind(code)) || by_status(status)

    message =
      first_printable([
        body_text(body, "message"),
        body_text(body, "error_description"),
        detail(body),
        code && sentence(code, %{})
      ]) || unexplained(where, status, code)

    {:error, kind, message}
  end

  @doc """
  What an application answered a call of `capability` with, when it is not a success
  (`EhOsContract.Plug`'s table): the sentence of its refusal, of its kind. `where` is the
  application's address.
  """
  @spec application(HTTP.answer(), String.t(), String.t()) :: error()
  def application(%{status: status, body: body}, capability, where) do
    case body do
      %{"refused" => reason} when is_binary(reason) ->
        {:error, kind(reason) || :refused,
         sentence(reason, %{capability: capability}) || refused(reason)}

      %{"rejected" => invariant} when is_binary(invariant) ->
        {:error, :invalid, "The application refused it: #{shown(invariant)}."}

      %{"invalid" => %{} = fields} when map_size(fields) > 0 ->
        {:error, :invalid, "Some fields do not fit: " <> fields(fields) <> "."}

      %{"error" => code} when is_binary(code) ->
        {:error, kind(code) || by_status(status),
         sentence(code, %{capability: capability}) || unexplained(where, status, code)}

      _other ->
        {:error, by_status(status), unexplained(where, status, nil)}
    end
  end

  @doc """
  refusals.md's sentence for `code`, when it has one that needs nothing filled in.

      iex> Ehosctl.Refusal.sentence("expired")
      "Your sign-in has expired. Run `ehosctl login`."
  """
  @spec sentence(String.t()) :: String.t() | nil
  def sentence(code), do: sentence(code, %{capability: nil})

  # refusals.md's sentences for what EHOS's API and an application answer with a code alone.
  defp sentence(code, _ctx) when code in ~w(missing no_credential),
    do: "You are not signed in. Run `ehosctl login`."

  defp sentence("expired", _ctx), do: "Your sign-in has expired. Run `ehosctl login`."

  defp sentence(code, _ctx) when code in ~w(unknown_key no_keys),
    do:
      "This installation does not recognise the key your credential was signed with. Sign in " <>
        "again; if it happens again, the application has not yet learned EHOS's keys."

  defp sentence(code, _ctx) when code in ~w(bad_signature malformed),
    do: "Your credential is damaged or was not issued by EHOS. Sign in again."

  defp sentence("wrong_issuer", _ctx),
    do: "Your credential was issued by another installation. Choose this one and sign in to it."

  defp sentence("wrong_audience", _ctx),
    do: "Your credential is for another application or environment."

  defp sentence("disabled", _ctx),
    do: "Your account is disabled. Ask someone who manages people to enable it."

  defp sentence("unknown_principal", _ctx),
    do: "This installation does not know who your credential names. Sign in again."

  defp sentence("workload", _ctx), do: "An application's credential may only read the people."

  defp sentence("no_capability", _ctx),
    do:
      "None of your roles grants anything in that application and environment, so no " <>
        "credential was issued. Ask for a role binding there."

  defp sentence("missing_capability", %{capability: capability}) when is_binary(capability),
    do:
      "You may not do this: it needs `#{shown(capability)}`, which none of your roles grants " <>
        "here. Ask for a role binding that does."

  # The application names the reason alone, not the field, so the sentence cannot either.
  defp sentence("unscoped_grant", _ctx),
    do: "Your role grants this only for some values of a field, and the role binding gives none."

  defp sentence("outside_scope", _ctx), do: "Your role does not grant this for that value."

  defp sentence("not_found", %{capability: capability}) when is_binary(capability),
    do: "The application has no `#{shown(capability)}`. Run `ehosctl apps` to see what it offers."

  defp sentence("not_created", _ctx),
    do: "That has not been created, so nothing can be recorded about it yet."

  defp sentence("idempotency_key_required", _ctx),
    do: "Creating this needs an idempotency key; `ehosctl` makes one unless you give your own."

  defp sentence("idempotency_key_invalid", _ctx),
    do: "An idempotency key is printable ASCII of at most 255 bytes."

  defp sentence("key_too_long", _ctx), do: "A value that names it is too long."

  defp sentence("body_is_not_a_json_object", _ctx),
    do: "The request could not be read: its body is not a JSON object."

  defp sentence("unreadable_body", _ctx),
    do: "The request could not be read: its body could not be read."

  defp sentence("invalid_query_string", _ctx),
    do: "The request could not be read: its query string is not one the application reads."

  defp sentence("correlation_id_is_not_a_uuid", _ctx),
    do: "The request could not be read: its correlation id is not a UUID."

  defp sentence("idempotency_key_reused", _ctx),
    do: "That idempotency key was used for something else. Use a new one."

  defp sentence("conflict", _ctx), do: "Something changed it at the same moment. Try again."
  defp sentence("subject_erased", _ctx), do: "The personal data asked for was erased."

  defp sentence("not_supplied", _ctx),
    do:
      "The application could not fill in a value it supplies itself, and nothing was written. " <>
        "Try again."

  defp sentence("no_actor", _ctx),
    do: "The application did not receive your credential. Run `ehosctl login`."

  defp sentence(_code, _ctx), do: nil

  defp refused(reason), do: "The application refused it (#{shown(reason)})."

  # `invalid`'s problems: refusals.md's words for each, an invariant's name for the rest.
  defp fields(fields) do
    fields
    |> Enum.sort()
    |> Enum.map_join("; ", fn {field, problem} -> "`#{shown(field)}` #{problem(problem)}" end)
  end

  defp problem("required"), do: "is required"
  defp problem("type"), do: "is of the wrong type"
  defp problem(given) when given in ["generated", "supplied"], do: "is given by the application"
  defp problem("unknown"), do: "names something the application does not have"
  defp problem(invariant) when is_binary(invariant), do: "breaks `#{shown(invariant)}`"
  defp problem(other), do: "does not fit (#{shown(other)})"

  defp by_status(401), do: :not_signed_in
  defp by_status(403), do: :refused
  defp by_status(status) when status in [400, 414, 422], do: :invalid
  defp by_status(429), do: :unreachable
  defp by_status(status) when status >= 500, do: :unreachable
  defp by_status(_status), do: :failed

  defp unexplained(where, status, nil) when status >= 500,
    do: "#{where} is unavailable (HTTP #{status}). Try again later."

  defp unexplained(where, status, nil), do: "#{where} answered HTTP #{status}."
  defp unexplained(where, status, code), do: "#{where} answered HTTP #{status}: #{shown(code)}."

  defp code(%{"error" => code}) when is_binary(code), do: code
  defp code(_body), do: nil

  defp body_text(%{} = body, key), do: if(is_binary(body[key]), do: body[key])
  defp body_text(_body, _key), do: nil

  # The routes EHOS has not moved to refusals.md's form yet: `{"errors": {"detail": …}}`.
  defp detail(%{"errors" => %{"detail" => detail}}) when is_binary(detail), do: detail
  defp detail(_body), do: nil

  defp first_printable(texts),
    do: Enum.find(texts, &(is_binary(&1) and &1 != "" and Output.printable?(&1)))

  @doc """
  `value` as it can be printed to a terminal: itself when it can be (`Ehosctl.Output.printable?/1`),
  else quoted with its escapes.

      iex> Ehosctl.Refusal.shown("amount")
      "amount"

      iex> Ehosctl.Refusal.shown("a\\e[2J")
      ~S("a\\e[2J")
  """
  @spec shown(term()) :: String.t()
  def shown(value) when is_binary(value),
    do: if(Output.printable?(value), do: value, else: inspect(value))

  def shown(value), do: inspect(value)
end
