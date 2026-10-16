defmodule Ehosctl.Trusts do
  @moduledoc """
  `ehosctl trust list | add | remove`: an application's trusts of GitHub repositories, which let
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
  to workflows from fork pull requests" off, and one that accepts tags without `--protected`
  lets anyone who can push a tag deploy.

  A trust is named by the id `list` prints, which is its deployment identity's.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.GitHub
  alias Ehosctl.Output
  alias Ehosctl.Refusal

  @look "`ehosctl trust list`"
  @repository ~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\/[A-Za-z0-9._-]{1,100}\z/

  @warnings %{
    "pull_requests" =>
      "It accepts pull requests: keep the repository's \"Send write tokens to workflows from " <>
        "fork pull requests\" off, or a fork's pull request deploys as the person who opened it.",
    "tags" =>
      "It accepts tags without --protected: anyone who can push to the repository can push a " <>
        "tag no ruleset protects, and deploy with it."
  }

  @impl Ehosctl.Command
  def name, do: :trust

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def spec do
    app = [
      long: "--app",
      value_name: "APPLICATION",
      required: true,
      help: "The application whose trusts these are."
    ]

    [
      about:
        "List, add and remove the GitHub repositories whose Actions jobs may deploy to an " <>
          "application's ephemeral environments with no stored secret.",
      subcommands: [
        list: [
          name: "list",
          about: "List an application's trusts in force, newest first.",
          options: [app: app],
          flags:
            [
              removed: [
                long: "--removed",
                help: "List the 100 newest removed trusts too."
              ]
            ] ++ Output.json_flag()
        ],
        add: [
          name: "add",
          about:
            "Trust a GitHub repository's Actions jobs on the refs given, and, if given, only in " <>
              "those GitHub environments, on protected refs or from one workflow.",
          options: [
            app: app,
            repo: [
              long: "--repo",
              value_name: "OWNER/NAME",
              required: true,
              help: "The repository, as GitHub names it."
            ],
            ref: [
              long: "--ref",
              value_name: "REF",
              multiple: true,
              required: true,
              help:
                "A ref it accepts, exact (refs/heads/main) or with * for one segment " <>
                  "(refs/pull/*/merge); repeat for several, at most twenty."
            ],
            environment: [
              long: "--environment",
              value_name: "NAME",
              multiple: true,
              help: "Accept only a job in this GitHub environment; repeat for several."
            ],
            workflow: [
              long: "--workflow",
              value_name: "PATH",
              help:
                "Accept only this workflow, .github/workflows/<file>.yml; it narrows only on a " <>
                  "protected ref."
            ],
            owner_id: [
              long: "--owner-id",
              value_name: "ID",
              parser: :integer,
              help: "The repository's owner's id on GitHub, instead of asking GitHub."
            ],
            repo_id: [
              long: "--repo-id",
              value_name: "ID",
              parser: :integer,
              help: "The repository's id on GitHub, instead of asking GitHub."
            ]
          ],
          flags:
            [
              protected: [
                long: "--protected",
                help: "Accept only a ref GitHub reports protected."
              ]
            ] ++ Output.json_flag()
        ],
        remove: [
          name: "remove",
          about:
            "Remove a trust: the next job is refused, and so is every call by a credential " <>
              "already given.",
          args: [
            trust: [
              value_name: "TRUST",
              required: true,
              help: "The trust's id, as `list` prints it."
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
        &added(&1, app)
      )
    end
  end

  def call([:remove], %{args: %{trust: id}}, _opts) when id in ["", ".", ".."],
    do: {:error, :invalid, "#{Refusal.shown(id)} names no trust."}

  def call([:remove], parsed, opts) do
    id = parsed.args.trust
    app = parsed.options.app

    Api.write(
      opts,
      {:delete, path(app) <> "/" <> URI.encode(id, &URI.char_unreserved?/1), nil},
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
        "Removed the trust of #{Refusal.shown(trust["repository"])} in #{Refusal.shown(app)}: " <>
          "its next job is refused, and so is any credential it was given."
      end
    )
  end

  defp path(app),
    do: "/api/v1/applications/#{URI.encode(app, &URI.char_unreserved?/1)}/deployment-trusts"

  defp repository_named(repo) do
    if Regex.match?(@repository, repo),
      do: :ok,
      else:
        {:error, :invalid,
         "#{Refusal.shown(repo)} is not a GitHub repository: name it as OWNER/NAME."}
  end

  # Both ids given are taken as they are, with the name as typed; one alone is a mistake.
  defp ids(repo, %{owner_id: owner_id, repo_id: repo_id}, _opts)
       when is_integer(owner_id) and is_integer(repo_id) do
    if owner_id > 0 and repo_id > 0,
      do: {:ok, %{full_name: repo, owner_id: owner_id, id: repo_id}},
      else: {:error, :invalid, "--owner-id and --repo-id are GitHub's ids, above zero."}
  end

  defp ids(repo, %{owner_id: nil, repo_id: nil}, opts), do: GitHub.repository_ids(repo, opts)

  defp ids(_repo, _options, _opts),
    do: {:error, :invalid, "--owner-id and --repo-id go together: give both, or neither."}

  defp added(trust, app) do
    warnings =
      trust["warnings"]
      |> Enum.map(&Map.get(@warnings, &1, "EHOS warns: #{Refusal.shown(&1)}."))
      |> Enum.map_join(&("\n" <> &1))

    "Trusted #{Refusal.shown(trust["repository"])} in #{Refusal.shown(app)} on " <>
      "#{list(trust["refs"])}#{narrowed(trust)}: trust #{Refusal.shown(trust["id"])}." <> warnings
  end

  defp narrowed(trust) do
    [
      trust["environments"] != [] && " in the environments #{list(trust["environments"])}",
      trust["ref_protected"] && ", protected refs only",
      is_binary(trust["workflow"]) && ", from #{Refusal.shown(trust["workflow"])} only"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join()
  end

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

  defp table(app, []), do: "#{Refusal.shown(app)} trusts no GitHub repository."

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
