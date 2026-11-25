# EhosApp.Review's tests run real git in repositories of their own, and so does the code they
# test, which runs git with the environment it inherits. Set once, before any test starts, for
# both: no global or system configuration, so a developer's hooks (`core.hooksPath`), signing or
# fsmonitor never run on a test commit, and a broken one fails nothing; no `GIT_TEMPLATE_DIR`,
# whose hooks `git init` would copy into the test's repository; and none of the variables git
# names as a repository's own (`git rev-parse --local-env-vars`: `GIT_DIR`, `GIT_INDEX_FILE`,
# `GIT_COMMON_DIR`, a caller's `-c` as `GIT_CONFIG_PARAMETERS` and the like), which a git hook
# running `mix check` inherits, and which would point every `git -C <tmp_dir>` at another
# repository, record a mark there, or bring the caller's configuration back (ehos-tools#591).
# packages/review's test helper isolates its tests the same way.
#
# The tests that read ehos_contract over the network (`EhosApp.EhosContractReleaseTest`) need
# the caller's credentials: CI's token, as `GIT_CONFIG_COUNT` with the key and value the helper
# leaves alone, or a developer's credential helper in the global configuration. The caller's
# value of those three, `nil` when unset, is kept for them to give back to their own git alone.
credentials = ["GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_COUNT"]
:persistent_term.put(:ehos_app_caller_git, Enum.map(credentials, &{&1, System.get_env(&1)}))

System.put_env(%{"GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1"})
{local_vars, 0} = System.cmd("git", ["rev-parse", "--local-env-vars"])
Enum.each(["GIT_TEMPLATE_DIR" | String.split(local_vars)], &System.delete_env/1)

# Every test's `tmp_dir` is under `tmp/` here, inside this repository: git searching from one
# stops below `tmp/` rather than finding ehos-tools, so a `tmp_dir` that holds no repository of
# its own is in none (ehos-tools#606).
System.put_env("GIT_CEILING_DIRECTORIES", Path.expand("tmp"))

# What `mix ehos_app.review pull_request` reads, which a developer may have exported to try it:
# its test reads the process's environment with no description in it.
System.delete_env("PULL_REQUEST_BODY")

Hammox.defmock(EhosApp.EnvMock, for: EhosApp.Env)
Hammox.defmock(EhosApp.ClaudeMock, for: EhosApp.Claude)
Hammox.defmock(EhosApp.CommandMock, for: EhosApp.Command)

# The tests of a generated project (`test/generated_project/`) need one, its dependencies and its
# database: CI's `e2e` job runs them, after `ehosctl init`.
ExUnit.start(exclude: [:ehos_contract, :generated_project])
