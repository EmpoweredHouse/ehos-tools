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

  test "fetches the dependencies with the GitHub token from a build secret, for EHOS's two private repositories alone" do
    content = with_dockerfile(@phoenix) |> dockerfile()

    assert content =~ "RUN --mount=type=secret,id=github_token,required=true \\\n"

    assert content =~
             ~s|GIT_CONFIG_KEY_0="url.https://x-access-token:$(cat /run/secrets/github_token)@github.com/EmpoweredHouse/eh-os-contract.insteadOf"|

    assert content =~ ~s|GIT_CONFIG_VALUE_0="https://github.com/EmpoweredHouse/eh-os-contract"|
    assert content =~ "GIT_CONFIG_COUNT=2 \\\n"

    assert content =~
             ~s|GIT_CONFIG_KEY_1="url.https://x-access-token:$(cat /run/secrets/github_token)@github.com/EmpoweredHouse/ehos-tools.insteadOf"|

    assert content =~ ~s|GIT_CONFIG_VALUE_1="https://github.com/EmpoweredHouse/ehos-tools"|
    assert content =~ ~r/  mix deps.get --only \$MIX_ENV\nRUN mkdir config\n\z/
    refute content =~ "RUN mix deps.get"
  end

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

  test "gives the step ehos_app 0.2 wrote the second repository, ehos-tools" do
    content = with_dockerfile(@step_0_2) |> dockerfile()

    assert content =~ "GIT_CONFIG_COUNT=2 \\\n"
    assert content =~ ~s|GIT_CONFIG_VALUE_1="https://github.com/EmpoweredHouse/ehos-tools"|
    assert content == with_dockerfile(@phoenix) |> dockerfile()
  end

  test "says what to add to a secret step of the developer's that names eh-os-contract alone" do
    changed = String.replace(@step_0_2, "# install mix dependencies", "# ours")
    changed = String.replace(changed, "eh_os_contract is read", "eh_os_contract, read")
    igniter = with_dockerfile(changed)

    assert_unchanged(igniter)
    assert Enum.any?(igniter.notices, &(&1 =~ "Give that step the second repository"))
  end

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

  test "fetches Tailwind with curl before `mix assets.setup`, checked against the release's sums" do
    content = with_dockerfile(@phoenix_assets) |> dockerfile()

    assert content =~
             "--no-install-recommends build-essential git curl ca-certificates \\\n"

    assert content =~
             ~s|bin="$(mix run --no-start --no-compile -e 'IO.write(Tailwind.bin_path())')"|

    assert content =~
             ~s|curl -fsSL --retry 3 --retry-all-errors -o "$bin" "$base/tailwindcss-$target"|

    assert content =~ ~S|sed -n "s# ./tailwindcss-$target\$# $bin#p" /tmp/tailwind.sums|
    assert content =~ "sha256sum -c /tmp/tailwind.check"
    assert content =~ ~r/RUN mix deps.compile\n\n# The tailwind package/
    assert content =~ ~r/  && chmod \+x "\$bin"\n\nRUN mix assets.setup\n\nCOPY priv priv\n\z/
    assert content =~ "GIT_CONFIG_COUNT=2"
  end

  test "gives a project's Dockerfile with the build secret already the fetch alone" do
    with_secret = with_dockerfile(@phoenix_assets) |> dockerfile()

    before =
      with_secret
      |> String.replace(" curl ca-certificates", "")
      |> String.replace(~r/# The tailwind package.*chmod \+x "\$bin"\n\n/s, "")

    assert before =~ "GIT_CONFIG_COUNT=2"
    refute before =~ "Tailwind"
    assert with_dockerfile(before) |> dockerfile() == with_secret
  end

  test "leaves a `mix assets.setup` the developer commented out alone" do
    commented = String.replace(@phoenix_assets, "RUN mix assets.setup", "# RUN mix assets.setup")
    content = with_dockerfile(commented) |> dockerfile()

    refute content =~ "Tailwind"
    assert content =~ "\n# RUN mix assets.setup\n"
  end

  test "leaves a Dockerfile that fetches Tailwind already alone" do
    fetched =
      String.replace(@phoenix_assets, "RUN mix assets.setup", """
      RUN bin="$(mix run --no-start --no-compile -e 'IO.write(Tailwind.bin_path())')" && curl -o "$bin" ours
      RUN mix assets.setup\
      """)

    content = with_dockerfile(fetched) |> dockerfile()

    refute content =~ "curl ca-certificates"
    refute content =~ "# The tailwind package"
  end

  test "leaves a Dockerfile whose build dependencies are not Phoenix's alone, and says what to add" do
    changed =
      String.replace(@phoenix_assets, "build-essential git \\", "build-essential git ours \\")

    content = with_dockerfile(changed) |> dockerfile()
    igniter = with_dockerfile(changed)

    refute content =~ "Tailwind"
    assert Enum.any?(igniter.notices, &(&1 =~ "IO.write(Tailwind.bin_path())"))
  end

  test "is idempotent: a second run changes nothing" do
    with_dockerfile(@phoenix_assets)
    |> apply_igniter!()
    |> Igniter.compose_task("ehos_app.dockerfile", [])
    |> assert_unchanged()
  end

  test "leaves a Dockerfile without Phoenix's step alone, and says what to change" do
    igniter = with_dockerfile("# changed by the developer\n")

    assert_unchanged(igniter)
    assert Enum.any?(igniter.notices, &(&1 =~ "--mount=type=secret,id=github_token"))
  end

  test "does nothing without a Dockerfile" do
    test_project()
    |> Igniter.compose_task("ehos_app.dockerfile", [])
    |> assert_unchanged()
  end
end
