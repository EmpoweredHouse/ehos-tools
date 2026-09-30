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

  test "fetches the dependencies with the GitHub token from a build secret, for eh-os-contract alone" do
    content = with_dockerfile(@phoenix) |> dockerfile()

    assert content =~ "RUN --mount=type=secret,id=github_token,required=true \\\n"

    assert content =~
             ~s|GIT_CONFIG_KEY_0="url.https://x-access-token:$(cat /run/secrets/github_token)@github.com/EmpoweredHouse/eh-os-contract.insteadOf"|

    assert content =~ ~s|GIT_CONFIG_VALUE_0="https://github.com/EmpoweredHouse/eh-os-contract"|
    assert content =~ ~r/  mix deps.get --only \$MIX_ENV\nRUN mkdir config\n\z/
    refute content =~ "RUN mix deps.get"
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
