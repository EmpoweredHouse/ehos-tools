defmodule Mix.Tasks.EhosApp.Dockerfile.Docs do
  @moduledoc false

  def short_doc,
    do: "Makes the Dockerfile read EHOS's private dependencies through a BuildKit secret"

  def example, do: "mix ehos_app.dockerfile"

  def long_doc do
    """
    #{short_doc()}

    `eh_os_contract` and `ehos_design` are read from private repositories. This changes the
    one step of the Dockerfile `mix phx.gen.release --docker` generates that fetches
    dependencies, so that it reads a GitHub token from the build secret `github_token`. The
    token reaches that step alone and no layer of the image:

        docker build --secret id=github_token,env=GITHUB_TOKEN .

    `mix ehos_app.install` runs it after `phx.gen.release`. A step this task wrote for
    `eh_os_contract` alone, before `ehos_design`, is given the second repository. A Dockerfile
    without that step, or one that has it already, is left as it is.

    ## Example

    ```sh
    #{example()}
    ```
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.EhosApp.Dockerfile do
    @shortdoc "#{__MODULE__.Docs.short_doc()}"
    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    # The step as `phx.gen.release --docker` writes it, from Phoenix 1.7 on.
    @deps_get "RUN mix deps.get --only $MIX_ENV\n"
    @secret "--mount=type=secret,id=github_token"

    # git takes the token through GIT_CONFIG_* for this one command, so it is written to no
    # file, and the URL `mix.lock` records stays the plain one.
    @deps_get_with_secret """
    # eh_os_contract and ehos_design are read from private repositories, with a GitHub token
    # passed as the build secret `github_token`. It reaches this step alone and no layer of
    # the image:
    #
    #     docker build --secret id=github_token,env=GITHUB_TOKEN .
    RUN #{@secret},required=true \\
      GIT_CONFIG_COUNT=2 \\
      GIT_CONFIG_KEY_0="url.https://x-access-token:$(cat /run/secrets/github_token)@github.com/EmpoweredHouse/eh-os-contract.insteadOf" \\
      GIT_CONFIG_VALUE_0="https://github.com/EmpoweredHouse/eh-os-contract" \\
      GIT_CONFIG_KEY_1="url.https://x-access-token:$(cat /run/secrets/github_token)@github.com/EmpoweredHouse/ehos-tools.insteadOf" \\
      GIT_CONFIG_VALUE_1="https://github.com/EmpoweredHouse/ehos-tools" \\
      mix deps.get --only $MIX_ENV
    """

    # The step as ehos_app 0.2 wrote it, for eh_os_contract alone, which an upgrade replaces.
    @deps_get_with_secret_0_2 """
    # eh_os_contract is read from a private repository, with a GitHub token passed as the
    # build secret `github_token`. It reaches this step alone and no layer of the image:
    #
    #     docker build --secret id=github_token,env=GITHUB_TOKEN .
    RUN #{@secret},required=true \\
      GIT_CONFIG_COUNT=1 \\
      GIT_CONFIG_KEY_0="url.https://x-access-token:$(cat /run/secrets/github_token)@github.com/EmpoweredHouse/eh-os-contract.insteadOf" \\
      GIT_CONFIG_VALUE_0="https://github.com/EmpoweredHouse/eh-os-contract" \\
      mix deps.get --only $MIX_ENV
    """

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{group: :ehos, example: __MODULE__.Docs.example()}
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      igniter = Igniter.include_existing_file(igniter, "Dockerfile")

      if Igniter.exists?(igniter, "Dockerfile") do
        content = igniter.rewrite |> Rewrite.source!("Dockerfile") |> Rewrite.Source.get(:content)

        cond do
          String.contains?(content, @deps_get_with_secret_0_2) ->
            Igniter.update_file(igniter, "Dockerfile", fn source ->
              Rewrite.Source.update(source, :content, fn content ->
                String.replace(content, @deps_get_with_secret_0_2, @deps_get_with_secret,
                  global: false
                )
              end)
            end)

          content =~ @secret and not (content =~ "EmpoweredHouse/ehos-tools") ->
            Igniter.add_notice(igniter, """
            The Dockerfile's build secret reaches eh-os-contract alone, and ehos_design is read
            from ehos-tools. Give that step the second repository:

            #{@deps_get_with_secret}
            """)

          content =~ @secret ->
            igniter

          content =~ @deps_get ->
            Igniter.update_file(igniter, "Dockerfile", fn source ->
              Rewrite.Source.update(source, :content, fn content ->
                String.replace(content, @deps_get, @deps_get_with_secret, global: false)
              end)
            end)

          true ->
            Igniter.add_notice(igniter, """
            The Dockerfile has no `#{String.trim(@deps_get)}` step, so it was left alone. To
            build it, give that step the GitHub token as a build secret:

            #{@deps_get_with_secret}
            """)
        end
      else
        igniter
      end
    end
  end
else
  defmodule Mix.Tasks.EhosApp.Dockerfile do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"
    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'ehos_app.dockerfile' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installing-igniter
      """)

      exit({:shutdown, 1})
    end
  end
end
