defmodule Mix.Tasks.EhosApp.DockerfileTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  # The lines around the step, as `phx.gen.release --docker` writes them in Phoenix 1.8.
  @phoenix """
  # install mix dependencies
  COPY mix.exs mix.lock ./
  RUN mix deps.get --only $MIX_ENV
  RUN mkdir config
  """

  # The step as ehos_app 0.2 wrote it, before ehos_design.
  @step_0_2 """
  # install mix dependencies
  COPY mix.exs mix.lock ./
  # eh_os_contract is read from a private repository, with a GitHub token passed as the
  # build secret `github_token`. It reaches this step alone and no layer of the image:
  #
  #     docker build --secret id=github_token,env=GITHUB_TOKEN .
  RUN --mount=type=secret,id=github_token,required=true \\
    GIT_CONFIG_COUNT=1 \\
    GIT_CONFIG_KEY_0="url.https://x-access-token:$(cat /run/secrets/github_token)@github.com/EmpoweredHouse/eh-os-contract.insteadOf" \\
    GIT_CONFIG_VALUE_0="https://github.com/EmpoweredHouse/eh-os-contract" \\
    mix deps.get --only $MIX_ENV
  RUN mkdir config
  """

  # The build dependencies and the assets step, as `phx.gen.release --docker` writes them in
  # Phoenix 1.8 for a project with assets.
  @phoenix_assets """
  # install build dependencies
  RUN apt-get update \\
    && apt-get install -y --no-install-recommends build-essential git \\
    && rm -rf /var/lib/apt/lists/*

  #{@phoenix}
  COPY config/config.exs config/${MIX_ENV}.exs config/
  RUN mix deps.compile

  RUN mix assets.setup

  COPY priv priv
  """

  # The step that fetches the dependencies with the GitHub token from the build secret, for
  # EHOS's two private repositories alone.
  @secret_step """
  # ehos_contract and ehos_design are read from private repositories, with a GitHub token
  # passed as the build secret `github_token`. It reaches this step alone and no layer of
  # the image:
  #
  #     docker build --secret id=github_token,env=GITHUB_TOKEN .
  RUN --mount=type=secret,id=github_token,required=true \\
    GIT_CONFIG_COUNT=2 \\
    GIT_CONFIG_KEY_0="url.https://x-access-token:$(cat /run/secrets/github_token)@github.com/EmpoweredHouse/ehos_contract.insteadOf" \\
    GIT_CONFIG_VALUE_0="https://github.com/EmpoweredHouse/ehos_contract" \\
    GIT_CONFIG_KEY_1="url.https://x-access-token:$(cat /run/secrets/github_token)@github.com/EmpoweredHouse/ehos-tools.insteadOf" \\
    GIT_CONFIG_VALUE_1="https://github.com/EmpoweredHouse/ehos-tools" \\
    mix deps.get --only $MIX_ENV
  """

  # The step as 0.3.0 to 0.37 wrote it, for the library under its name before 0.16.0.
  @secret_step_0_37 @secret_step
                    |> String.replace("# ehos_contract and", "# eh_os_contract and")
                    |> String.replace(
                      "EmpoweredHouse/ehos_contract",
                      "EmpoweredHouse/eh-os-contract"
                    )

  # Phoenix's lines around the step, the step given the build secret.
  @with_secret """
  # install mix dependencies
  COPY mix.exs mix.lock ./
  #{@secret_step}\
  RUN mkdir config
  """

  # The layer that fetches Tailwind with curl, checked against the release's sums.
  @tailwind_fetch """
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

  # Phoenix's Dockerfile for a project with assets, with the build secret, curl among the build
  # dependencies, and Tailwind fetched before `mix assets.setup`.
  @phoenix_assets_fetched """
  # install build dependencies
  RUN apt-get update \\
    && apt-get install -y --no-install-recommends build-essential git curl ca-certificates \\
    && rm -rf /var/lib/apt/lists/*

  #{@with_secret}
  COPY config/config.exs config/${MIX_ENV}.exs config/
  RUN mix deps.compile

  #{@tailwind_fetch}
  RUN mix assets.setup

  COPY priv priv
  """

  test "fetches the dependencies with the GitHub token from a build secret, for EHOS's two private repositories alone" do
    assert with_dockerfile(@phoenix) |> dockerfile() == @with_secret
  end

  test "gives the step ehos_app 0.2 wrote the library's new repository and ehos-tools" do
    assert with_dockerfile(@step_0_2) |> dockerfile() == @with_secret
  end

  test "gives the step ehos_app 0.3.0 to 0.37 wrote the library's new repository" do
    step = String.replace(@with_secret, @secret_step, @secret_step_0_37)
    assert step != @with_secret
    assert with_dockerfile(step) |> dockerfile() == @with_secret
  end

  test "says what to change in a secret step of the developer's that names the library's old repository" do
    step = String.replace(@with_secret, @secret_step, @secret_step_0_37)
    changed = String.replace(step, "# install mix dependencies", "# ours")
    changed = String.replace(changed, "eh_os_contract and", "eh_os_contract, and")
    igniter = with_dockerfile(changed)

    assert_unchanged(igniter)

    assert igniter.notices == [
             """
             The Dockerfile's build secret does not reach EmpoweredHouse/ehos_contract, the
             contract library's repository since it was renamed from eh-os-contract. Give that step
             the repository's new address:

             #{@secret_step}
             """
           ]
  end

  test "fetches Tailwind with curl before `mix assets.setup`, checked against the release's sums" do
    assert with_dockerfile(@phoenix_assets) |> dockerfile() == @phoenix_assets_fetched
  end

  test "gives a project's Dockerfile with the build secret already the fetch alone" do
    with_secret = String.replace(@phoenix_assets, @phoenix, @with_secret)

    assert with_dockerfile(with_secret) |> dockerfile() == @phoenix_assets_fetched
  end

  test "is idempotent: a second run changes nothing" do
    with_dockerfile(@phoenix_assets)
    |> apply_igniter!()
    |> Igniter.compose_task("ehos_app.dockerfile", [])
    |> assert_unchanged()
  end

  test "says what to add to a secret step of the developer's that names ehos_contract alone" do
    changed = String.replace(@step_0_2, "# install mix dependencies", "# ours")
    changed = String.replace(changed, "eh_os_contract is read", "ehos_contract, read")

    changed =
      String.replace(changed, "EmpoweredHouse/eh-os-contract", "EmpoweredHouse/ehos_contract")

    igniter = with_dockerfile(changed)

    assert_unchanged(igniter)

    assert igniter.notices == [
             """
             The Dockerfile's build secret reaches ehos_contract alone, and ehos_design is read
             from ehos-tools. Give that step the second repository:

             #{@secret_step}
             """
           ]
  end

  test "leaves a `mix assets.setup` the developer commented out alone" do
    commented = String.replace(@phoenix_assets, "RUN mix assets.setup", "# RUN mix assets.setup")

    assert with_dockerfile(commented) |> dockerfile() ==
             String.replace(commented, @phoenix, @with_secret)
  end

  test "leaves a Dockerfile that fetches Tailwind already alone" do
    fetched =
      String.replace(@phoenix_assets, "RUN mix assets.setup", """
      RUN bin="$(mix run --no-start --no-compile -e 'IO.write(Tailwind.bin_path())')" && curl -o "$bin" ours
      RUN mix assets.setup\
      """)

    assert with_dockerfile(fetched) |> dockerfile() ==
             String.replace(fetched, @phoenix, @with_secret)
  end

  test "leaves a Dockerfile whose build dependencies are not Phoenix's alone, and says what to add" do
    changed =
      String.replace(@phoenix_assets, "build-essential git \\", "build-essential git ours \\")

    igniter = with_dockerfile(changed)

    assert dockerfile(igniter) == String.replace(changed, @phoenix, @with_secret)

    assert igniter.notices == [
             """
             The Dockerfile's build dependencies are not Phoenix's, so Tailwind's fetch was not
             added. Its `mix assets.setup` downloads Tailwind with Erlang's :httpc, which GitHub's
             release redirect refuses. Install curl and ca-certificates in the builder, and fetch
             it before that step:

             #{@tailwind_fetch}

             """
           ]
  end

  test "leaves a Dockerfile without Phoenix's step alone, and says what to change" do
    igniter = with_dockerfile("# changed by the developer\n")

    assert_unchanged(igniter)

    assert igniter.notices == [
             """
             The Dockerfile has no `RUN mix deps.get --only $MIX_ENV` step, so it was left alone. To
             build it, give that step the GitHub token as a build secret:

             #{@secret_step}
             """
           ]
  end

  test "does nothing without a Dockerfile" do
    test_project()
    |> Igniter.compose_task("ehos_app.dockerfile", [])
    |> assert_unchanged()
  end

  defp with_dockerfile(content) do
    test_project()
    |> Igniter.create_new_file("Dockerfile", content)
    |> apply_igniter!()
    |> Igniter.compose_task("ehos_app.dockerfile", [])
  end

  # After `apply_igniter!/1`, the test project reads back only `**/*.*`, which leaves out
  # `Dockerfile`; it is in its `test_files`.
  defp dockerfile(igniter) do
    igniter
    |> apply_igniter!()
    |> Map.fetch!(:assigns)
    |> Map.fetch!(:test_files)
    |> Map.fetch!("Dockerfile")
  end
end
