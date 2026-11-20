defmodule Ehosctl.Trusts do
  @moduledoc """
  `ehosctl trusts list | add | remove`: an application's trusts of GitHub repositories, which let
  a GitHub Actions job there deploy to the application's ephemeral environments with the token
  GitHub gives it and no stored secret, through EHOS's API (eh-os
  [`docs/deployment-identity-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/deployment-identity-api.md),
  [D-110](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0110-a-pipeline-deploys-as-its-application-s-deployment-identity-trusted-per-github-repository-exchanging-github-actions-token-for-a-credential-that-reaches-only-ephemeral-environments.md)),
  as the application's **Deployments from CI** page does.

  Setting and removing a trust need `ehos.role_binding.manage` and `ehos.application.deploy` on
  the application; listing needs either. EHOS decides and records each call, and its refusal is
  printed in its words.

  A trust names its repository by the ids GitHub gives it and its owner, since a name can be
  taken again by someone else. EHOS makes no call to GitHub, so `add` reads them from GitHub's
  API (`Ehosctl.GitHub.repository_ids/2`), with `MISE_GITHUB_TOKEN` or `GITHUB_TOKEN` for a
  private repository, unless `--owner-id` and `--repo-id` give them. The warnings EHOS answers
  with are printed: a trust that accepts pull requests needs the repository's "Send write tokens
  to workflows from fork pull requests" off; one that accepts tags without `--protected` lets
  anyone who can push a tag deploy; and one that accepts pull requests beside a branch or tag
  without `--protected` lets anyone who can push such a ref reach every preview of the
  application, not one pull request's (eh-os
  [D-121](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0121-a-pipeline-credential-exchanged-for-a-pull-request-reaches-only-that-pull-request-s-ephemeral-environment.md)).

  A trust is named by the id `list` prints, which is its deployment identity's.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.GitHub
  alias Ehosctl.Output
  alias Ehosctl.Refusal

  require Ehosctl.Api

  @look "`ehosctl trusts list`"
  @repository ~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\/[A-Za-z0-9._-]{1,100}\z/

  # EHOS's warnings, each as its head and its explanation.
  @warnings %{
    "pull_requests" =>
      {"The trust accepts pull requests.",
       "Keep \"Send write tokens to workflows from fork pull requests\" off in the repository. " <>
         "If it is on, a pull request from a fork deploys as the person who opened it."},
    "tags" =>
      {"The trust accepts tags without --protected.",
       "Each person who can push to the repository can push a tag that no ruleset protects, " <>
         "and deploy with it."},
    "branches" =>
      {"The trust accepts pull requests and also branches or tags, without --protected.",
       "The run of a pull request reaches only its own preview. But each person who can push a " <>
         "branch or a tag that this trust accepts can run a job there and reach each preview of " <>
         "the application. To stop this, remove the trust and add it again for " <>
         "'refs/pull/*/merge' only. Do not use --protected for it: GitHub protects no ref of a " <>
         "pull request, so EHOS would refuse each run of a pull request."}
  }

  @impl Ehosctl.Command
  def name, do: :trusts

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def group, do: :access

  @impl Ehosctl.Command
  def summary, do: "Let the GitHub Actions jobs of a repository deploy."

  @impl Ehosctl.Command
  def spec do
    app = [
      long: "--app",
      value_name: "APPLICATION",
      required: true,
      help: "The application that trusts the repositories."
    ]

    [
      about:
        "List, add and remove trusts. A trust lets the GitHub Actions jobs of a repository " <>
          "deploy to the ephemeral environments of an application, with no stored secret.",
      subcommands: [
        list: [
          name: "list",
          about: "List the trusts in force of an application, newest first.",
          options: [app: app],
          flags:
            [
              removed: [
                long: "--removed",
                help: "Also list the 100 newest removed trusts."
              ]
            ] ++ Output.json_flag()
        ],
        add: [
          name: "add",
          about:
            "Trust the GitHub Actions jobs of a repository on the refs that you give. You can " <>
              "limit the trust to GitHub environments, protected refs or one workflow.",
          options: [
            app: app,
            repo: [
              long: "--repo",
              value_name: "OWNER/NAME",
              required: true,
              help: "The repository on GitHub, as OWNER/NAME."
            ],
            ref: [
              long: "--ref",
              value_name: "REF",
              multiple: true,
              required: true,
              help:
                "A ref that the trust accepts: exact, as refs/heads/main, or with * for one " <>
                  "segment, as refs/pull/*/merge. Repeat for more, up to 20."
            ],
            environment: [
              long: "--environment",
              value_name: "NAME",
              multiple: true,
              help: "Accept only a job in this GitHub environment. Repeat for more."
            ],
            workflow: [
              long: "--workflow",
              value_name: "PATH",
              help:
                "Accept only this workflow, as .github/workflows/<file>.yml. It applies only " <>
                  "on a protected ref."
            ],
            owner_id: [
              long: "--owner-id",
              value_name: "ID",
              parser: :integer,
              help:
                "The id of the owner of the repository on GitHub. With --repo-id, ehosctl does " <>
                  "not ask GitHub."
            ],
            repo_id: [
              long: "--repo-id",
              value_name: "ID",
              parser: :integer,
              help:
                "The id of the repository on GitHub. With --owner-id, ehosctl does not ask " <>
                  "GitHub."
            ]
          ],
          flags:
            [
              protected: [
                long: "--protected",
                help: "Accept only a ref that GitHub reports as protected."
              ]
            ] ++ Output.json_flag()
        ],
        remove: [
          name: "remove",
          about:
            "Remove a trust. EHOS refuses the next job, and each call with a credential that " <>
              "it already gave.",
          args: [
            trust: [
              value_name: "TRUST",
              required: true,
              help: "The id of the trust, as `ehosctl trusts list` shows it."
            ]
          ],
          options: [app: app],
          flags: Output.json_flag()
        ]
      ]
    ]
  end

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  # An application that would leave its place in the path (`.`, `..`), or names nothing, is
  # refused before anything is sent: a proxy that resolves dot segments would send it elsewhere.
  def call(_command, %{options: %{app: app}}, _opts) when Api.is_nameless(app),
    do:
      {:error, :invalid,
       "#{inspect(app)} is not the name of an application. Give the name of the application " <>
         "with --app."}

  def call([:list], parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)
    app = parsed.options.app
    query = if parsed.flags.removed, do: "?removed=true", else: ""

    with {:ok, %{"trusts" => trusts}} when is_list(trusts) <-
           Api.read(installation, path(app) <> query, opts),
         true <- Enum.all?(trusts, &trust?/1) || Api.unexpected(installation) do
      trusts = Enum.map(trusts, &only/1)
      {:ok, %{text: table(app, trusts), json: %{application: app, trusts: trusts}}}
    else
      {:ok, _body} -> Api.unexpected(installation)
      error -> error
    end
  end

  def call([:add], parsed, opts) do
    %{app: app, repo: repo, ref: refs, environment: environments, workflow: workflow} =
      parsed.options

    with :ok <- repository_named(repo),
         {:ok, ids} <- ids(repo, parsed.options, opts) do
      body =
        Map.reject(
          %{
            repository: ids.full_name,
            repository_owner_id: ids.owner_id,
            repository_id: ids.id,
            refs: refs,
            environments: environments || [],
            ref_protected: parsed.flags.protected,
            workflow: workflow
          },
          &is_nil(elem(&1, 1))
        )

      Api.write(
        opts,
        {:post, path(app), body},
        [
          status: 201,
          key: "trust",
          valid?: &(trust?(&1) and &1["repository_id"] == ids.id),
          only: &only/1,
          look: @look
        ],
        &added(&1, app, parsed.flags[:json] == true)
      )
    end
  end

  def call([:remove], %{args: %{trust: id}}, _opts) when Api.is_nameless(id),
    do:
      {:error, :invalid,
       "#{inspect(id)} is not the id of a trust. Run `ehosctl trusts list` to see the ids."}

  def call([:remove], parsed, opts) do
    id = parsed.args.trust
    app = parsed.options.app

    Api.write(
      opts,
      {:delete, path(app) <> "/" <> Api.segment(id), nil},
      [
        status: 200,
        key: "trust",
        # The trust asked for, and no other, is what EHOS says it removed: a UUID, which EHOS
        # reads in either case and answers in lower case.
        valid?: &(trust?(&1) and String.downcase(&1["id"]) == String.downcase(id)),
        only: &only/1,
        look: @look
      ],
      fn trust ->
        "Removed the trust of #{Refusal.shown(trust["repository"])} in #{Refusal.shown(app)}. " <>
          "EHOS refuses its next job, and each credential that EHOS already gave it."
      end
    )
  end

  defp path(app),
    do: "/api/v1/applications/#{Api.segment(app)}/deployment-trusts"

  defp repository_named(repo) do
    if Regex.match?(@repository, repo) and Path.basename(repo) not in [".", ".."],
      do: :ok,
      else:
        {:error, :invalid,
         "#{Refusal.shown(repo)} is not the name of a GitHub repository. Give it as " <>
           "OWNER/NAME."}
  end

  # Both ids given are taken as they are, with the name as typed; one alone is a mistake.
  defp ids(repo, %{owner_id: owner_id, repo_id: repo_id}, _opts)
       when is_integer(owner_id) and is_integer(repo_id) do
    if owner_id > 0 and repo_id > 0,
      do: {:ok, %{full_name: repo, owner_id: owner_id, id: repo_id}},
      else:
        {:error, :invalid,
         "--owner-id and --repo-id must be above zero, as each id on GitHub is. Give the ids " <>
           "that GitHub shows."}
  end

  defp ids(repo, %{owner_id: nil, repo_id: nil}, opts), do: GitHub.repository_ids(repo, opts)

  defp ids(_repo, _options, _opts),
    do: {:error, :invalid, "--owner-id and --repo-id go together. Give both, or neither."}

  # What the trust accepts, as values; EHOS's warnings on stderr, not under --json.
  defp added(trust, app, json?) do
    if not json? do
      for code <- trust["warnings"] do
        {head, explanation} =
          Map.get(@warnings, code, {"EHOS warns: #{Refusal.shown(code)}.", nil})

        Output.warn(head, explanation)
      end
    end

    Output.lines([
      Output.outcome(
        :done,
        "Trusted #{Refusal.shown(trust["repository"])} in #{Refusal.shown(app)}."
      ),
      Output.values(
        [{"Trust", Refusal.shown(trust["id"])}, {"Refs", lines(trust["refs"])}] ++ narrowed(trust)
      )
    ])
  end

  defp narrowed(trust) do
    [
      trust["environments"] != [] && {"Environments", lines(trust["environments"])},
      trust["ref_protected"] && {"Ref protection", "protected refs only"},
      is_binary(trust["workflow"]) && {"Workflow", Refusal.shown(trust["workflow"])}
    ]
    |> Enum.filter(&is_tuple/1)
  end

  # Each on a line of its own, under its label.
  defp lines(names), do: Enum.map_join(names, "\n", &Refusal.shown/1)

  defp list(names), do: Enum.map_join(names, ", ", &Refusal.shown/1)

  @fields ~w(id repository repository_owner_id repository_id refs environments ref_protected
             workflow warnings created_by_id created_at removed_by_id removed_at)

  defp only(trust), do: Map.take(trust, @fields)

  defp trust?(%{"id" => id, "repository" => repository} = trust)
       when is_binary(id) and is_binary(repository),
       do:
         positive?(trust["repository_owner_id"]) and positive?(trust["repository_id"]) and
           texts?(trust["refs"]) and texts?(trust["environments"]) and
           is_boolean(trust["ref_protected"]) and nil_or_text?(trust["workflow"]) and
           texts?(trust["warnings"]) and nil_or_text?(trust["removed_at"])

  defp trust?(_trust), do: false

  defp positive?(value), do: is_integer(value) and value > 0
  defp texts?(list), do: is_list(list) and Enum.all?(list, &is_binary/1)
  defp nil_or_text?(value), do: is_nil(value) or is_binary(value)

  defp table(app, []),
    do:
      "#{Refusal.shown(app)} trusts no GitHub repository. A trust shows here when a person " <>
        "adds it with `ehosctl trusts add`."

  defp table(_app, trusts) do
    trusts
    |> Enum.map(fn trust ->
      %{
        "REPOSITORY" => Refusal.shown(trust["repository"]),
        "REFS" => list(trust["refs"]),
        "ONLY" => only_where(trust),
        "STATE" => if(trust["removed_at"], do: "removed", else: "in force"),
        "ID" => Refusal.shown(trust["id"])
      }
    end)
    |> Output.table(["REPOSITORY", "REFS", "ONLY", "STATE", "ID"])
  end

  defp only_where(trust) do
    [
      trust["environments"] != [] && "environments #{list(trust["environments"])}",
      trust["ref_protected"] && "protected refs",
      is_binary(trust["workflow"]) && Refusal.shown(trust["workflow"])
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("; ")
  end
end
