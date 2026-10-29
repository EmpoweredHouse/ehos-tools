defmodule Ehosctl.RefusalTest do
  use Ehosctl.Case, async: true

  alias Ehosctl.Refusal

  doctest Ehosctl.Refusal

  # Every code eh-os's docs/refusals.md names, by the kind its exit code comes from, as of
  # https://github.com/EmpoweredHouse/eh-os/blob/34e72c827d29ebcabafcbdecd77439ce61c50d44/docs/refusals.md
  # Not signed in and Not accepted are `:not_signed_in`; Not found, Conflict and Gone are `:failed`.
  # The lists are read from that commit's kinds table and sentence tables, leaving out what the
  # text in parentheses names; to refresh them, read them again from a newer commit, and give
  # `Ehosctl.Refusal` the codes this test then finds without a kind.
  @refusals_md %{
    not_signed_in:
      ~w(bad_signature disabled expired malformed missing no_actor no_credential no_keys
                       revoked signed_out unknown_key unknown_principal wrong_audience wrong_issuer),
    refused: ~w(beyond_inviter beyond_owner beyond_rule deployment_identity escalation forbidden
                 missing_capability no_capability no_console no_role outside_scope presented
                 unscoped_grant workload not_agreed beyond_agreement),
    failed: ~w(already_bound already_linked already_registered already_requested already_set
                binding_moved build_not_found candidate_gone changed conflict database_kept
                default_taken host_too_long idempotency_key_reused in_use joined
                last_administrator mail_required name_taken name_too_long no_application
                no_room no_template not_a_candidate not_classified
                not_created not_found not_in_force not_its_environment not_production
                not_requested object_taken person_disabled promotion_required readers_not_held
                requester_cannot_deploy schema_taken secret_unresolved self self_approval
                subject_erased superseded template_above_ceiling too_many_agents
                too_many_ephemeral too_many_for_application too_many_trusts unbound
                unknown_audience unknown_scope used would_be_refused wider_than_asked domain_not_asked
                hosts_not_deployed),
    invalid: ~w(across_the_line application_required body_is_not_a_json_object
                 confirmation_required correlation_id_is_not_a_uuid ephemeral expiry_too_long
                 idempotency_key_invalid idempotency_key_required invalid invalid_email
                 invalid_expiry invalid_image invalid_name invalid_query_string key_too_long
                 name_not_its_own needs_environment not_claimable not_ephemeral platform_only
                 production_only rejected repository_required schema_reserved schema_too_long
                 schema_too_long_elsewhere too_large unknown_role unreadable_body value_in_query
                 wrong_application),
    unreachable: ~w(being_removed cluster_refused ehos_unavailable logs_unavailable not_mailed
                     not_supplied secrets_unavailable temporarily_unavailable too_many_calls
                     too_many_invitations too_many_tails mail_disabled too_many_messages)
  }

  # refusals.md's sentences that need nothing filled in, from its sentence tables at the commit
  # above. Those that hold a value are left out. For an application's answer, ehosctl fills in
  # `missing_capability`'s and `not_found`'s capability, `rejected`'s invariant and `invalid`'s
  # fields. It says what of a request could not be read in a sentence of its own for each code
  # (`@unread`), and `unscoped_grant` and `outside_scope`, for which an application names no
  # field, without one (`@without_field`). EHOS says `too_many_calls` and `too_large` itself, in
  # `message`, with the seconds or the bytes only it knows, and the row for text EHOS cannot store
  # has no code.
  @sentences %{
    "bad_signature" => "Your credential is damaged or was not issued by EHOS. Sign in again.",
    "conflict" => "Something changed it at the same moment. Try again.",
    "deployment_identity" =>
      "A pipeline's credential may only make, deploy to and remove its application's ephemeral environments.",
    "disabled" => "Your account is disabled. Ask someone who manages people to enable it.",
    "expired" => "Your sign-in has expired. Run `ehosctl login`.",
    "idempotency_key_invalid" => "An idempotency key is printable ASCII of at most 255 bytes.",
    "idempotency_key_required" =>
      "Creating this needs an idempotency key; `ehosctl` makes one unless you give your own.",
    "idempotency_key_reused" =>
      "That idempotency key was used for something else. Use a new one.",
    "key_too_long" => "A value that names it is too long.",
    "malformed" => "Your credential is damaged or was not issued by EHOS. Sign in again.",
    "missing" => "You are not signed in. Run `ehosctl login`.",
    "no_actor" => "The application did not receive your credential. Run `ehosctl login`.",
    "no_capability" =>
      "None of your roles grants anything in that application and environment, so no credential was issued. Ask for a role binding there.",
    "no_console" =>
      "Your account opens its applications, not EHOS itself. Ask someone who manages bindings to bind you ehos.member.",
    "no_credential" => "You are not signed in. Run `ehosctl login`.",
    "no_keys" =>
      "This installation does not recognise the key your credential was signed with. Sign in again; if it happens again, the application has not yet learned EHOS's keys.",
    "not_created" => "That has not been created, so nothing can be recorded about it yet.",
    "not_supplied" =>
      "The application could not fill in a value it supplies itself, and nothing was written. Try again.",
    "presented" =>
      "A credential an application exchanged for you may only grant a role its rule lets yours give, through that application.",
    "revoked" =>
      "This pipeline's credential no longer holds: its trust was removed, or the person it acts for was disabled, unlinked from the GitHub account, or lost `ehos.application.deploy`.",
    "subject_erased" => "The personal data asked for was erased.",
    "unknown_key" =>
      "This installation does not recognise the key your credential was signed with. Sign in again; if it happens again, the application has not yet learned EHOS's keys.",
    "unknown_principal" =>
      "This installation does not know who your credential names. Sign in again.",
    "workload" => "An application's credential may only read the people and send mail.",
    "wrong_audience" => "Your credential is for another application or environment.",
    "wrong_issuer" =>
      "Your credential was issued by another installation. Choose this one and sign in to it."
  }

  # refusals.md's sentences with their `<field>` said without it.
  @without_field %{
    "unscoped_grant" =>
      "Your role grants this only for some values of a field, and the role binding gives none.",
    "outside_scope" => "Your role does not grant this for that value."
  }

  # The four codes of a request that could not be read, whose sentences start as refusals.md's,
  # and say in ehosctl's words what could not be read.
  @unread %{
    "body_is_not_a_json_object" =>
      "The request could not be read: its body is not a JSON object.",
    "unreadable_body" => "The request could not be read: its body could not be read.",
    "invalid_query_string" =>
      "The request could not be read: its query string is not one the application reads.",
    "correlation_id_is_not_a_uuid" =>
      "The request could not be read: its correlation id is not a UUID."
  }

  # The codes refusals.md gives EHOS's API alone, for a pipeline's or a console's credential.
  @credential_codes ~w(deployment_identity no_console presented revoked)

  test "every sentence refusals.md gives a code is ehosctl's, word for word" do
    for {code, sentence} <- @sentences do
      assert {code, Refusal.sentence(code)} == {code, sentence}
    end
  end

  test "the sentences ehosctl says in its own words for a value refusals.md leaves open" do
    assert MapSet.disjoint?(
             MapSet.new(Map.keys(@sentences)),
             MapSet.new(Map.keys(@without_field))
           )

    for {code, sentence} <- @without_field do
      assert {code, Refusal.sentence(code)} == {code, sentence}
    end

    for {code, sentence} <- @unread do
      assert {code, Refusal.sentence(code)} == {code, sentence}
    end
  end

  test "a refusal whose sentence holds a number EHOS knows is said in EHOS's message" do
    for {status, code, kind, message} <- [
          {429, "too_many_calls", :unreachable, "Too many calls. Try again in 12 seconds."},
          {413, "too_large", :invalid, "The document is larger than 1048576 bytes."}
        ] do
      body = %{"error" => code, "message" => message}
      assert Refusal.ehos(%{status: status, body: body}, "EHOS") == {:error, kind, message}
    end
  end

  test "EHOS's refusal of a credential with no message is said in refusals.md's sentence" do
    assert Refusal.ehos(%{status: 401, body: %{"error" => "revoked"}}, "EHOS") ==
             {:error, :not_signed_in, @sentences["revoked"]}

    for code <- @credential_codes, code != "revoked" do
      assert Refusal.ehos(%{status: 403, body: %{"error" => code}}, "EHOS") ==
               {:error, :refused, Map.fetch!(@sentences, code)}
    end
  end

  test "an application answering with one of EHOS's credential codes is read as its own" do
    where = "https://shop.example.com"

    for code <- @credential_codes do
      assert Refusal.application(%{status: 409, body: %{"error" => code}}, "orders.cancel", where) ==
               {:error, :failed, "#{where} answered HTTP 409: #{code}."}

      assert Refusal.application(
               %{status: 403, body: %{"refused" => code}},
               "orders.cancel",
               where
             ) ==
               {:error, :refused, "The application refused it (#{code})."}
    end
  end

  test "every code refusals.md names has its kind" do
    for {kind, codes} <- @refusals_md, code <- codes do
      assert {code, Refusal.kind(code)} == {code, kind}
    end
  end

  test "an account that may not use EHOS's console is refused, in EHOS's words, at any status" do
    message = "Your account opens its applications, not EHOS itself."
    body = %{"error" => "no_console", "message" => message}

    assert Refusal.kind("no_console") == :refused
    assert Refusal.ehos(%{status: 400, body: body}, "EHOS") == {:error, :refused, message}
  end
end
