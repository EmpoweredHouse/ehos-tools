defmodule Mix.Tasks.EhosApp.Dockerfile.Docs do
  @moduledoc false

  def short_doc,
    do:
      "Makes the Dockerfile read EHOS's private dependencies through a BuildKit secret, and fetch Tailwind with curl"

  def example, do: "mix ehos_app.dockerfile"

  def long_doc do
    """
    #{short_doc()}

    `eh_os_contract` and `ehos_design` are read from private repositories. This changes the
    one step of the Dockerfile `mix phx.gen.release --docker` generates that fetches
    dependencies, so that it reads a GitHub token from the build secret `github_token`. The
    token reaches that step alone and no layer of the image:

        docker build --secret id=github_token,env=GITHUB_TOKEN .

    It also fetches Tailwind's executable with curl before `mix assets.setup`, which would
    download it with Erlang's `:httpc`: GitHub's release redirect has passed `:httpc`'s limit on
    a response's headers since 23 October 2026, so the build fails without it
    ([eh-os#973](https://github.com/EmpoweredHouse/eh-os/issues/973)). The version, the target
    and the path are the `tailwind` package's own, and the executable is checked against the
    release's `sha256sums.txt`. curl is installed beside Phoenix's build dependencies.

    `mix ehos_app.install` runs it after `phx.gen.release`. A step this task wrote for
    `eh_os_contract` alone, before `ehos_design`, is given the second repository. A Dockerfile
    without Phoenix's steps, or one that has these changes already, is left as it is.

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

    # The lines as `phx.gen.release --docker` writes them: the build dependencies' end, which
    # Phoenix 1.7 and 1.8 share, and the step that downloads Tailwind and esbuild.
    @build_dependencies "build-essential git \\\n"
    @build_dependencies_with_curl "build-essential git curl ca-certificates \\\n"
    @assets_setup "RUN mix assets.setup\n"

    # sha256sum fails on an empty check file, so a target missing from the sums refuses the
    # build rather than passing it.
    @fetch_tailwind """
    # The tailwind package downloads its executable with Erlang's :httpc, whose 10 KiB limit on
    # a response's headers GitHub's release redirect passes since 23 October 2026, so a build
    # without this layer cached fails (EmpoweredHouse/eh-os#973). curl fetches it instead, for
    # the architecture being built, checked against the release's own sha256sums.txt, into the
    # path the package looks in; `mix assets.setup` then finds it and downloads nothing.
    RUN version="$(mix run --no-start --no-compile -e 'IO.write(Tailwind.configured_version())')" \\
      && target="$(mix run --no-start --no-compile -e 'IO.write(Tailwind.configured_target())')" \\
      && bin="$(mix run --no-start --no-compile -e 'IO.write(Tailwind.bin_path())')" \\
      && base="https://github.com/tailwindlabs/tailwindcss/releases/download/v${version}" \\
      && mkdir -p "$(dirname "$bin")" \\
      && curl -fsSL --retry 3 --retry-all-errors -o "$bin" "$base/tailwindcss-$target" \\
      && curl -fsSL --retry 3 --retry-all-errors -o /tmp/tailwind.sums "$base/sha256sums.txt" \\
      && sed -n "s# ./tailwindcss-$target\\$# $bin#p" /tmp/tailwind.sums > /tmp/tailwind.check \\
      && sha256sum -c /tmp/tailwind.check \\
      && rm /tmp/tailwind.sums /tmp/tailwind.check \\
      && chmod +x "$bin"

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

        igniter
        |> build_secret(content)
        |> fetch_tailwind(content)
      else
        igniter
      end
    end

    defp build_secret(igniter, content) do
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
    end

    # Only `phx.gen.release`'s own lines are changed. Without `mix assets.setup` there is no
    # Tailwind to fetch; a Dockerfile that reads `Tailwind.bin_path()` fetches it already.
    defp fetch_tailwind(igniter, content) do
      cond do
        content =~ "Tailwind.bin_path()" or not (content =~ @assets_setup) ->
          igniter

        content =~ @build_dependencies ->
          Igniter.update_file(igniter, "Dockerfile", fn source ->
            Rewrite.Source.update(source, :content, fn content ->
              content
              |> String.replace(@build_dependencies, @build_dependencies_with_curl, global: false)
              |> String.replace(@assets_setup, @fetch_tailwind <> @assets_setup, global: false)
            end)
          end)

        true ->
          Igniter.add_notice(igniter, """
          The Dockerfile's build dependencies are not Phoenix's, so Tailwind's fetch was not
          added. Its `mix assets.setup` downloads Tailwind with Erlang's :httpc, which GitHub's
          release redirect refuses. Install curl and ca-certificates in the builder, and fetch
          it before that step:

          #{@fetch_tailwind}
          """)
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
