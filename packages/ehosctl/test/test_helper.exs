# Some tests run real git: in repositories of their own (`Ehosctl.CheckoutTest`, the builds a
# GitHub Actions job registers), through `Ehosctl.RunnerImpl` as the code they test does, and in
# this checkout (`Ehosctl.TemplateTest`, which reads its tags). Set once, before any test starts,
# for all of them: no global or system configuration, so a developer's hooks (`core.hooksPath`),
# signing or fsmonitor never run on a test commit, and a broken one fails nothing; no
# `GIT_TEMPLATE_DIR`, whose hooks `git init` would copy into the test's repository; and none of
# the variables git names as a repository's own (`git rev-parse --local-env-vars`: `GIT_DIR`,
# `GIT_INDEX_FILE`, `GIT_COMMON_DIR`, a caller's `-c` as `GIT_CONFIG_PARAMETERS` and the like),
# which a git hook running `mix check` inherits, and which would point every `git -C <tmp_dir>`
# at another repository or bring the caller's configuration back (ehos-tools#591).
# packages/review's and packages/ehos_app's test helpers isolate their tests the same way.
System.put_env(%{"GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1"})
{local_vars, 0} = System.cmd("git", ["rev-parse", "--local-env-vars"])
Enum.each(["GIT_TEMPLATE_DIR" | String.split(local_vars)], &System.delete_env/1)

Ehosctl.FakeKeychain.start()
Ehosctl.FakeIssuer.make_certificate()
# A test waits for a message to know that something happened, not to measure how long it took:
# a loaded machine can take more than ExUnit's 100 ms to send one (ehos-tools#1020).
ExUnit.start(assert_receive_timeout: 5_000)
