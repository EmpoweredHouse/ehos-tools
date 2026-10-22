defmodule Ehosctl.RefusalTest do
  use ExUnit.Case, async: true

  alias Ehosctl.Refusal

  doctest Ehosctl.Refusal

  # Every code eh-os's docs/refusals.md names, by the kind its exit code comes from, as of
  # https://github.com/EmpoweredHouse/eh-os/blob/b7eca7b02548a1d75a58f953867e6ccd326a474d/docs/refusals.md
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
                 unscoped_grant workload),
    failed: ~w(already_bound already_linked already_requested already_set binding_moved
                candidate_gone changed conflict database_kept default_taken host_too_long
                idempotency_key_reused in_use joined last_administrator mail_required name_taken
                name_too_long no_application no_template not_a_candidate not_classified
                not_created not_found not_in_force not_its_environment not_production
                not_requested object_taken person_disabled promotion_required readers_not_held
                requester_cannot_deploy schema_taken secret_unresolved self self_approval
                subject_erased superseded template_above_ceiling too_many_agents
                too_many_ephemeral too_many_for_application too_many_trusts unbound
                unknown_audience unknown_scope used would_be_refused),
    invalid: ~w(across_the_line application_required body_is_not_a_json_object
                 confirmation_required correlation_id_is_not_a_uuid expiry_too_long
                 idempotency_key_invalid idempotency_key_required invalid invalid_email
                 invalid_expiry invalid_image invalid_name invalid_query_string key_too_long
                 name_not_its_own needs_environment not_claimable not_ephemeral platform_only
                 production_only rejected schema_reserved schema_too_long
                 schema_too_long_elsewhere too_large unknown_role unreadable_body value_in_query
                 wrong_application),
    unreachable: ~w(being_removed cluster_refused ehos_unavailable logs_unavailable not_mailed
                     not_supplied secrets_unavailable temporarily_unavailable too_many_calls
                     too_many_invitations too_many_tails)
  }

  # refusals.md's sentences for EHOS's API's refusals of a pipeline's and a console's credential,
  # at the commit above.
  @credential_sentences %{
    "deployment_identity" =>
      "A pipeline's credential may only make, deploy to and remove its application's " <>
        "ephemeral environments.",
    "no_console" =>
      "Your account opens its applications, not EHOS itself. " <>
        "Ask someone who manages bindings to bind you ehos.member.",
    "presented" =>
      "A credential an application exchanged for you may only grant a role its rule lets " <>
        "yours give, through that application.",
    "revoked" =>
      "This pipeline's credential no longer holds: its trust was removed, or the person it " <>
        "acts for was disabled, unlinked from the GitHub account, or lost " <>
        "`ehos.application.deploy`."
  }

  test "EHOS's refusal of a credential with no message is said in refusals.md's sentence" do
    assert Refusal.ehos(%{status: 401, body: %{"error" => "revoked"}}, "EHOS") ==
             {:error, :not_signed_in, @credential_sentences["revoked"]}

    for {code, sentence} <- @credential_sentences, code != "revoked" do
      assert Refusal.ehos(%{status: 403, body: %{"error" => code}}, "EHOS") ==
               {:error, :refused, sentence}
    end
  end

  test "an application answering with one of EHOS's credential codes is read as its own" do
    where = "https://shop.example.com"

    for code <- Map.keys(@credential_sentences) do
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
