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

  alias Ehosctl.Failure
  alias Ehosctl.HTTP
  alias Ehosctl.Output

  @typedoc """
  An error of a kind, with its message, and, for a refusal EHOS's API answered with its code, what
  `--json` prints beside them (`Ehosctl.Output.error/4`).
  """
  @type error ::
          {:error, Output.kind(), Failure.message()}
          | {:error, Output.kind(), Failure.message(), Output.refusal()}

  @not_signed_in ~w(missing no_credential expired signed_out no_actor
                    unknown_key bad_signature wrong_issuer wrong_audience malformed no_keys
                    disabled unknown_principal revoked)
  @refused ~w(forbidden missing_capability outside_scope unscoped_grant no_capability no_role
              escalation beyond_owner beyond_inviter workload no_console deployment_identity
              presented beyond_rule not_agreed beyond_agreement not_a_person)
  @failed ~w(not_found no_route build_not_found no_application no_template not_its_environment
             unknown_audience unknown_scope not_created
             already_bound in_use joined person_disabled last_administrator self superseded
             changed conflict idempotency_key_reused subject_erased
             unbound database_kept name_taken name_too_long host_too_long object_taken
             schema_taken binding_moved no_room already_set not_classified used not_in_force
             too_many_agents not_requested too_many_entries
             too_many_for_application too_many_ephemeral template_above_ceiling
             default_taken already_linked too_many_trusts mail_required already_registered
             promotion_required
             secret_unresolved not_a_candidate not_production would_be_refused candidate_gone
             self_approval requester_cannot_deploy already_requested readers_not_held
             wider_than_asked domain_not_asked too_many_callers no_hosts hosts_changed
             callers_changed callers_not_held already_open already_ended too_many_sessions
             no_database outside_installation session_refused)
  @invalid ~w(invalid repository_required rejected invalid_image too_large across_the_line
              schema_too_long
              schema_too_long_elsewhere schema_reserved idempotency_key_required idempotency_key_invalid
              key_too_long body_is_not_a_json_object unreadable_body invalid_query_string
              correlation_id_is_not_a_uuid unknown_role platform_only production_only needs_environment
              wrong_application application_required confirmation_required expiry_too_long
              invalid_expiry not_ephemeral ephemeral value_in_query invalid_email
              invalid_name
              not_claimable name_not_its_own platform_role environment_only)
  @unreachable ~w(cluster_refused being_removed not_mailed ehos_unavailable not_supplied too_many_calls
                  temporarily_unavailable logs_unavailable too_many_tails
                  secrets_unavailable too_many_invitations mail_disabled too_many_messages
                  too_many_links instance_full not_applied)

  @doc """
  The kind of a refusal's code, or `nil` for a code refusals.md does not name.

      iex> Ehosctl.Refusal.kind("missing_capability")
      :refused

      iex> Ehosctl.Refusal.kind("expired")
      :not_signed_in

      iex> Ehosctl.Refusal.kind("production_only")
      :invalid
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

  A refusal with EHOS's code carries it, as `"code"`, for `--json` to print beside the kind and
  the sentence (ehos-tools#781).
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

    coded(kind, message, code)
  end

  defp coded(kind, message, nil), do: {:error, kind, message}
  defp coded(kind, message, code), do: {:error, kind, message, %{"code" => code}}

  @doc """
  `error` with `more` added to its message, keeping what it carries for `--json`, and added to the
  sentence it carries for `--json` where it has one (`Ehosctl.AtCount`).

      iex> Ehosctl.Refusal.added({:error, :failed, "Refused.", %{"code" => "in_use"}}, " Look.")
      {:error, :failed, "Refused. Look.", %{"code" => "in_use"}}
  """
  @spec added(error(), String.t()) :: error()
  def added({:error, kind, message}, more), do: {:error, kind, Failure.added(message, more)}

  def added({:error, kind, message, %{"message" => said} = refusal}, more),
    do: {:error, kind, Failure.added(message, more), %{refusal | "message" => said <> more}}

  def added({:error, kind, message, refusal}, more),
    do: {:error, kind, Failure.added(message, more), refusal}

  @doc """
  `error` with its message turned by `fun`, keeping what it carries for `--json`: for what to do
  that `added/2`'s words cannot say (`Ehosctl.Failure`).
  """
  @spec updated(error(), (Failure.message() -> Failure.message())) :: error()
  def updated({:error, kind, message}, fun), do: {:error, kind, fun.(message)}
  def updated({:error, kind, message, refusal}, fun), do: {:error, kind, fun.(message), refusal}

  @doc """
  What an application answered a call of `capability` with, when it is not a success
  (`EhOsContract.Plug`'s table): the sentence of its refusal, of its kind. `where` is the
  application's address.
  """
  @spec application(HTTP.answer(), String.t(), String.t()) :: error()
  def application(%{status: status, body: body}, capability, where),
    do: application_refusal(body, status, capability, where)

  defp application_refusal(%{"refused" => reason}, _status, capability, _where)
       when is_binary(reason),
       do:
         {:error, application_kind(reason) || :refused,
          application_sentence(reason, capability) || refused(reason)}

  defp application_refusal(%{"rejected" => invariant}, _status, _capability, _where)
       when is_binary(invariant),
       do: {:error, :invalid, "The application refused it: #{shown(invariant)}."}

  defp application_refusal(%{"invalid" => %{} = fields}, _status, _capability, _where)
       when map_size(fields) > 0,
       do: {:error, :invalid, "Some fields do not fit: " <> fields(fields) <> "."}

  defp application_refusal(%{"error" => code}, status, capability, where) when is_binary(code),
    do:
      {:error, application_kind(code) || by_status(status),
       application_sentence(code, capability) || unexplained(where, status, code)}

  defp application_refusal(_other, status, _capability, where),
    do: {:error, by_status(status), unexplained(where, status, nil)}

  # The codes refusals.md gives EHOS's API alone, for a pipeline's or a console's credential: an
  # application answering with one means something of its own, and says it in its own words.
  @ehos_only ~w(deployment_identity presented revoked no_console)

  defp application_kind(code) when code in @ehos_only, do: nil
  defp application_kind(code), do: kind(code)

  defp application_sentence(code, _capability) when code in @ehos_only, do: nil
  defp application_sentence(code, capability), do: sentence(code, %{capability: capability})

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
      "This installation does not recognise the key that signed your credential. Sign in " <>
        "again. If the refusal comes again, the application does not have the keys of EHOS " <>
        "yet: try again later."

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

  defp sentence("workload", _ctx),
    do: "An application's credential may only read the people and send mail."

  defp sentence("deployment_identity", _ctx),
    do:
      "A pipeline's credential may only make, deploy to and remove its application's " <>
        "ephemeral environments."

  defp sentence("no_console", _ctx),
    do:
      "Your account opens its applications, not EHOS itself. " <>
        "Ask a person who manages role bindings to bind ehos.member to you."

  defp sentence("presented", _ctx),
    do:
      "A credential an application exchanged for you may only grant a role its rule lets " <>
        "yours give, through that application."

  defp sentence("revoked", _ctx),
    do:
      "This pipeline's credential no longer holds: its trust was removed, or the person it " <>
        "acts for was disabled, unlinked from the GitHub account, or lost " <>
        "`ehos.application.deploy`."

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
  else quoted with its escapes; cut at 64 KiB (`Ehosctl.Output.bounded/1`), and `inspect/1` at
  its own bound.

      iex> Ehosctl.Refusal.shown("amount")
      "amount"

      iex> Ehosctl.Refusal.shown("a\\e[2J")
      ~S("a\\e[2J")
  """
  @spec shown(term()) :: String.t()
  def shown(value) when is_binary(value),
    do: if(Output.printable?(value), do: Output.bounded(value), else: inspect(value))

  def shown(value), do: inspect(value)

  @doc """
  A name as `shown/1` says it, or `<none>` for one that is not there, null or empty, as kubectl
  says it in a table's cell: no name can be that, where a seed profile, say, may be named `none`,
  and an empty cell reads as not known.

      iex> Ehosctl.Refusal.named("ledger")
      "ledger"

      iex> Ehosctl.Refusal.named("")
      "<none>"
  """
  @spec named(term()) :: String.t()
  def named(name) when is_binary(name) and name != "", do: shown(name)
  def named(_none), do: "<none>"
end
