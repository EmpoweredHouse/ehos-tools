# The tests run real git in repositories of their own, and so does the code they test
# (EhosApp.Review, which runs git with the environment it inherits). Set once, before any test
# starts, for both: no global or system configuration, so a developer's hooks
# (`core.hooksPath`), signing or fsmonitor never run on a test commit, and a broken one fails
# nothing; no `GIT_TEMPLATE_DIR`, whose hooks `git init` would copy into the test's repository;
# and none of the variables git names as a repository's own (`git rev-parse --local-env-vars`:
# `GIT_DIR`, `GIT_INDEX_FILE`, `GIT_COMMON_DIR`, a caller's `-c` as `GIT_CONFIG_PARAMETERS` and
# the like), which a git hook running `mix check` inherits, and which would point every
# `git -C <tmp_dir>` at another repository, record a mark there, or bring the caller's
# configuration back (ehos-tools#591).
System.put_env(%{"GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1"})
{local_vars, 0} = System.cmd("git", ["rev-parse", "--local-env-vars"])
Enum.each(["GIT_TEMPLATE_DIR" | String.split(local_vars)], &System.delete_env/1)

Hammox.defmock(Review.GitMock, for: Review.Git)

ExUnit.start()
