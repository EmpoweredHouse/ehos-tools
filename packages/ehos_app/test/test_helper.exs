# EhosApp.Review's tests run real git in repositories of their own, and so does the code they
# test, which runs git with the environment it inherits. Set once, before any test starts, for
# both: no global or system configuration, so a developer's hooks (`core.hooksPath`), signing or
# fsmonitor never run on a test commit, and a broken one fails nothing; no `GIT_TEMPLATE_DIR`,
# whose hooks `git init` would copy into the test's repository; and none of the variables git
# names as a repository's own (`git rev-parse --local-env-vars`: `GIT_DIR`, `GIT_INDEX_FILE`,
# `GIT_COMMON_DIR`, a caller's `-c` as `GIT_CONFIG_PARAMETERS` and the like), which a git hook
# running `mix check` inherits, and which would point every `git -C <tmp_dir>` at another
# repository, record a mark there, or bring the caller's configuration back (ehos-tools#591).
# packages/review's test helper does the same.
#
# The caller's value of each, unset ones as `nil`, is kept for the tests that read eh-os-contract
# over the network (`EhosApp.EhOsContractReleaseTest`), which give it back to their own git alone:
# they read it with the caller's credentials, CI's token as `GIT_CONFIG_COUNT` with its key and
# value, or a developer's credential helper in the global configuration.
{local_vars, 0} = System.cmd("git", ["rev-parse", "--local-env-vars"])

isolated = [
  "GIT_CONFIG_GLOBAL",
  "GIT_CONFIG_NOSYSTEM",
  "GIT_TEMPLATE_DIR" | String.split(local_vars)
]

:persistent_term.put(:ehos_app_caller_git, Enum.map(isolated, &{&1, System.get_env(&1)}))

System.put_env(%{"GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1"})
Enum.each(isolated -- ["GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM"], &System.delete_env/1)

Hammox.defmock(EhosApp.EnvMock, for: EhosApp.Env)

ExUnit.start(exclude: [:eh_os_contract])
