defmodule EhosRelease.Workflows do
  @moduledoc """
  The check that a caller keeps the release App's key to the one workflow that releases (eh-os
  D-205, "The workflow and its access"; T-34): no workflow but `release-pull-request.yml`, and in
  ehos-tools `ehos-release.yml` itself, names the secrets `RELEASE_APP_CLIENT_ID` and
  `RELEASE_APP_PRIVATE_KEY` or the environment `release-app`. The environment's branch rule admits
  any workflow on `main`, so the key stays with that workflow only while no other names it.

  This holds against a mistake, as eh-os's test of D-197 does: a workflow that passes every secret
  (`secrets: inherit`, `toJSON(secrets)`) names neither.
  """

  alias EhosRelease.Source

  @dir ".github/workflows"
  @allowed ~w(.github/workflows/release-pull-request.yml .github/workflows/ehos-release.yml)
  @names ~r/RELEASE_APP_|release-app/i

  @doc "A refusal for each workflow of `source` that names the key or its environment, and may not."
  @spec key_refusals(Source.t()) :: [String.t()]
  def key_refusals(%Source{} = source) do
    case Source.list(source, @dir, [".yml", ".yaml"]) do
      {:ok, files} ->
        for file <- files, file not in @allowed, names?(source, file) do
          "#{file} names the release App's key or the environment release-app, " <>
            "which only release-pull-request.yml may"
        end

      {:error, reason} ->
        [reason]
    end
  end

  defp names?(source, file) do
    case Source.read(source, file) do
      {:ok, contents} -> contents =~ @names
      _missing_or_error -> true
    end
  end
end
