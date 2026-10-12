#!/usr/bin/env bash
# Merges an upstream Twenty release tag into the fork and verifies the result.
#
# Usage: sync-upstream.sh <tag> <merge|verify|commit>
#   merge   start `git merge --no-ff --no-commit <tag>` and auto-resolve what is
#           deterministic. Exit 0 = clean, 10 = conflicts remain.
#   verify  conflict-marker scan, install, build and typecheck. Last line is
#           VERIFY_OK or VERIFY_FAILED: <step>.
#   commit  conclude the merge. Refuses if conflict markers remain.
#
# The script owns the final commit on purpose: the commit message must stay free
# of any AI attribution, whoever resolved the conflicts.
set -euo pipefail

EXIT_CONFLICTS=10

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <tag> <merge|verify|commit>" >&2
  exit 2
fi

TAG=$1
MODE=$2

conflicted_paths() {
  git diff --name-only --diff-filter=U
}

has_conflict_markers() {
  # Anchored to the exact 7-char markers so docs that show "=======" rules
  # inside tables or underlines do not trip it.
  git grep -n -E '^(<<<<<<< |>>>>>>> )' -- \
    . ':(exclude).github/workflows' ':(exclude)*.md' ':(exclude)*.mdx' >&2
}

restore_workflows() {
  # GITHUB_TOKEN cannot push changes under .github/workflows, so the fork never
  # carries upstream's workflows: keep ours and drop whatever upstream added.
  git checkout HEAD -- .github/workflows
  local path
  while IFS= read -r path; do
    if ! git cat-file -e "HEAD:${path}" 2> /dev/null; then
      git rm -q -f --cached -- "$path"
      rm -f -- "$path"
    fi
  done < <(git ls-files .github/workflows | sort -u)
}

resolve_generated_locales() {
  # Compiled catalogs are derived from the .po files, so upstream's copy is
  # always right and verify regenerates them when the .po files changed.
  local path
  while IFS= read -r path; do
    case "$path" in
      */locales/generated/*)
        # `--theirs` is upstream's side in a merge. If upstream deleted the
        # file there is no "theirs" stage, so follow the deletion.
        if git checkout --theirs -- "$path" 2>/dev/null; then
          git add -- "$path"
        else
          git rm -q -f -- "$path"
        fi
        ;;
    esac
  done < <(conflicted_paths)
}

do_merge() {
  if git rev-parse -q --verify MERGE_HEAD > /dev/null; then
    echo "a merge is already in progress; refusing to start another" >&2
    exit 2
  fi

  git rev-parse -q --verify "refs/tags/${TAG}^{commit}" > /dev/null \
    || { echo "tag ${TAG} is not available locally; fetch it first" >&2; exit 2; }

  # A non-zero status here just means conflicts; the state is inspected below.
  git merge --no-ff --no-commit "$TAG" || true

  if ! git rev-parse -q --verify MERGE_HEAD > /dev/null; then
    echo "merge did not start (already up to date or failed before staging)" >&2
    exit 2
  fi

  restore_workflows
  resolve_generated_locales

  local remaining
  remaining=$(conflicted_paths)
  if [ -n "$remaining" ]; then
    echo "CONFLICTS_REMAIN:"
    echo "$remaining"
    exit "$EXIT_CONFLICTS"
  fi
  echo "MERGE_CLEAN"
}

changed_vs_head() {
  git diff --name-only HEAD -- "$@"
}

do_verify() {
  local step="start"
  trap 'echo "VERIFY_FAILED: ${step}"' ERR
  set -E

  step="conflict-markers"
  if has_conflict_markers; then
    echo "conflict markers found" >&2
    false
  fi
  if [ -n "$(conflicted_paths)" ]; then
    echo "unmerged paths remain" >&2
    false
  fi

  step="install"
  # The lockfile only legitimately changes when the merge brings dependency
  # updates; in that case a frozen install would reject a lockfile that is still
  # internally consistent with the merged package.json files, so allow a plain
  # install. Otherwise stay immutable so drift is caught.
  if [ -n "$(changed_vs_head yarn.lock)" ]; then
    yarn install
  else
    yarn install --immutable
  fi

  step="build twenty-shared"
  npx nx build twenty-shared --skip-nx-cache

  # Compiled catalogs are committed. Regenerate them only for packages whose
  # .po files changed in the merge; compile is deterministic and offline.
  local package
  for package in twenty-front twenty-server twenty-emails; do
    # The server keeps its catalogs under src/engine/core-modules/i18n/locales.
    if [ -n "$(changed_vs_head ":(glob)packages/${package}/**/locales/*.po")" ]; then
      step="lingui:compile ${package}"
      npx nx run "${package}:lingui:compile"
    fi
  done

  for package in twenty-front twenty-server twenty-emails; do
    step="typecheck ${package}"
    npx nx typecheck "$package"
  done

  trap - ERR
  echo "VERIFY_OK"
}

do_commit() {
  git rev-parse -q --verify MERGE_HEAD > /dev/null \
    || { echo "no merge in progress" >&2; exit 2; }

  if [ -n "$(conflicted_paths)" ] || has_conflict_markers; then
    echo "refusing to commit: conflicts or conflict markers remain" >&2
    exit "$EXIT_CONFLICTS"
  fi

  # -A, not -u: a resolver that ports our change into a new file leaves it
  # untracked, and a commit without it would pass verify here and break main.
  # .gitignore keeps install and build output out.
  git add -A

  git commit --no-verify -m "merge: upstream ${TAG} into fork"
}

case "$MODE" in
  merge) do_merge ;;
  verify) do_verify ;;
  commit) do_commit ;;
  *) echo "unknown mode: $MODE" >&2; exit 2 ;;
esac
