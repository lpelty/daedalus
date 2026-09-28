# core/tests/fixtures/tty/setup.bash — terminals for the tty-mode tests (spec §7.4).
# no_tty <cmd...> — run with NO controlling terminal (a new session): /dev/tty cannot be
# opened, as in a Claude Code Bash tool. Without it a bats run from a person's terminal
# would give the command that terminal and the test would wait for typing.
no_tty() { python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@" </dev/null; }
# type_into <line> <prompt substring> <cmd...> — run on a pty and type <line> at the prompt.
# The suite itself runs under Claude Code, which tty_answer refuses as an ancestor (plan 4
# Decision 32); DAEDALUS_TEST_TTY_ANCESTRY=skip lets the check pass, and transcriptlib
# honours it only for a home under the system temp directory — every fixture home, no deployment.
type_into() { local l="$1" p="$2"; shift 2; DAEDALUS_TEST_TTY_ANCESTRY=skip python3 "$BATS_TEST_DIRNAME/fixtures/tty/type-into.py" "$l" "$p" -- "$@"; }
# under_fake_agent <cmd...> — run <cmd> as the child of a process whose argv[0] is `claude`
# (what the ancestry check looks for), with the seam unset.
under_fake_agent() { env -u DAEDALUS_TEST_TTY_ANCESTRY bash -c 'exec -a claude /bin/bash -c "\"\$@\"; exit \$?" claude "$@"' _ "$@"; }
# under_named <name> <cmd...> — run <cmd> as the child of a process whose argv[0] is <name>
# (a stand-in for a multiplexer server in the ancestor chain), with the seam unset.
under_named() { local n="$1"; shift; env -u DAEDALUS_TEST_TTY_ANCESTRY bash -c 'n="$1"; shift; exec -a "$n" /bin/bash -c "\"\$@\"; exit \$?" "$n" "$@"' _ "$n" "$@"; }
