set shell := ["bash", "-cu"]

# runs just check
default:
    just check

# every tracked shell script outside private/, which git-crypt keeps encrypted
shell-files:
    @git ls-files | grep -v '^private/' | while read -r f; do \
        head -1 "$f" 2>/dev/null | grep -qE '^#!.*\b(bash|sh)\b' && echo "$f"; \
      done || true

# shellcheck every shell script (errors only - warnings are advisory here)
lint:
    just shell-files | xargs shellcheck -S error

# validate the GitHub Actions workflows
lint-actions:
    actionlint

# everything CI runs: shellcheck and actionlint
check:
    just lint
    just lint-actions
