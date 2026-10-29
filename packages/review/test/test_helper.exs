# The tests run real git in repositories of their own, and so does the code they test
# (EhosApp.Review, which runs git with the environment it inherits). Set once, before any test
# starts, for both: no global or system configuration, so a developer's hooks
# (`core.hooksPath`), signing or fsmonitor never run on a test commit, and no `GIT_DIR`,
# `GIT_WORK_TREE` or `GIT_INDEX_FILE` from a caller, such as a git hook running `mix check`, which
# would point every `git -C <tmp_dir>` at another repository and record a mark there
# (ehos-tools#591).
System.put_env(%{"GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1"})
Enum.each(["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"], &System.delete_env/1)

ExUnit.start()
