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

  test "is idempotent: a second run changes nothing" do
    with_dockerfile(@phoenix)
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
