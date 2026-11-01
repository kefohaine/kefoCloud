#!/usr/bin/env bash
#
# scripts/info/prose-audit.sh — keep comments and user-facing strings about the
# CURRENT configuration only. READ-ONLY: it reports, it never edits.
#
# Why it exists: a comment drifts the moment the thing it names changes, and the
# drift is invisible — nobody re-reads a compose header. Four kinds of prose go
# stale by construction, so they are not written at all (AGENTS rule 31):
#
#   DOCPOINTER  a path into docs/ (seen at every edit, true only until the doc
#               is renamed or the section moves) — the doc says where it is.
#   FIGURE      a size or a timing measured once on one host (GB/TB/MB of RAM,
#               "~23 s", "3-minute budget") — a claim about a machine that is
#               not the machine reading it.
#   HOST        another box of the operator's, or a live address of one (public
#               or tailnet IPv4 literals) — instance data, not config.
#   FUTURE      a plan or a guess ("future DB host", "planned", "eventually") —
#               the repo describes what runs now.
#   PENDING     an outstanding task, an open question or a live state
#               ("TODO", "TBD", "pending", "awaiting", "- [ ]") — those belong to
#               the Issues tab, where a human can close them; a doc that carries
#               one has no owner and never gets finished.
#
# Scope: every tracked file, in two passes. Comments and strings are checked for
# all four kinds; markdown is checked for PENDING only (docs carry the facts, so
# a size or a path there is the point). The gitignored `data/` tree and binaries
# are skipped. Exemptions, all deliberate: `recipes/*.yaml` — pointing an agent
# at the doc that holds the procedure is the recipe's whole job — the one
# `make migrate` line that prints the runbook, this file (it quotes the shapes),
# `docs/AGENTS.md` (states the rule), and the issue/PR templates (a checklist is
# what a template is).
#
# Usage: scripts/info/prose-audit.sh [file ...]   (default: the whole tree)
#   PROSE_AUDIT_OVERRIDE=1  report and exit 0
# Exit 1 when any finding is reported, so a hook can gate on it.

set -uo pipefail

REPO="${REPO_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)}"
cd "$REPO" || exit 1

if [ "$#" -gt 0 ]; then
  files=("$@")
else
  mapfile -t files < <(git ls-files \
    | grep -vE '(^docs/|\.md$|^data/|^\.github/(images|issues)/)' \
    | grep -vE '\.(png|jpg|jpeg|gif|webp|ico|pdf|gz|tar|zip|woff2?|ttf|lock)$')
fi

finding() { printf '  %-10s %s:%s %s\n' "$1" "$2" "$3" "$4"; }
fails=0

# IPv4 literals that belong to someone: skip private, loopback, link-local,
# CGNAT (tailscale), "any", and the doc-style placeholder ranges.
is_private_ip() {
  local ip="$1" a b c d
  IFS=. read -r a b c d <<<"$ip"
  [ "$a" -eq 10 ] && return 0
  [ "$a" -eq 127 ] && return 0
  [ "$a" -eq 0 ] && return 0
  [ "$a" -eq 169 ] && [ "$b" -eq 254 ] && return 0
  [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ] && return 0
  [ "$a" -eq 192 ] && [ "$b" -eq 168 ] && return 0
  [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ] && return 0
  [ "$a" -eq 255 ] && return 0
  return 1
}

for f in "${files[@]}"; do
  [ -f "$f" ] || continue
  # Two files quote the banned shapes by necessity: the recipes (pointing an
  # agent at the doc holding the procedure is their job) and this checker.
  case "$f" in recipes/*.yaml|scripts/info/prose-audit.sh) continue ;; esac

  n=0
  while IFS= read -r line; do
    n=$((n + 1))
    # The one line whose job is to print a doc: `make migrate`.
    case "$f:$line" in
      Makefile:*'cat $(REPO)/docs/MIGRATE.md'*) continue ;;
    esac

    if [[ $line =~ docs/(MANUAL|DEBUG|MIGRATE|SKELETON|AGENTS)\.md ]]; then
      finding DOCPOINTER "$f" "$n" "names a docs/ path"; fails=$((fails + 1))
    fi

    # Sizes and timings only where a human wrote a claim: a comment line.
    if [[ $line =~ ^[[:space:]]*(#|//|--) ]]; then
      if [[ $line =~ (^|[^_[:alnum:]])([0-9]+([.][0-9]+)?)[[:space:]]*(GB|TB|MB)([^[:alnum:]_]|$) ]]; then
        case "$line" in
          *mem_limit*|*memswap_limit*|*MEM_*|*swap*|*Swap*|*RAM/*) ;;
          *) finding FIGURE "$f" "$n" "states a memory size"; fails=$((fails + 1)) ;;
        esac
      fi
      if [[ $line =~ ~[[:space:]]*[0-9]+[[:space:]]*(s|min|sec)([^[:alnum:]]|$) ]]; then
        finding FIGURE "$f" "$n" "estimates a duration"; fails=$((fails + 1))
      fi
      if [[ $line =~ (future|someday|eventually|roadmap|planned|TODO|FIXME) ]]; then
        finding FUTURE "$f" "$n" "describes a plan or a guess"; fails=$((fails + 1))
      fi
      if [[ $line =~ operator\'s[[:space:]]+([0-9]+[[:space:]]*(GB|TB)|[A-Za-z]+[[:space:]]+(machine|box|Mac|laptop|desktop)) ]]; then
        finding HOST "$f" "$n" "names another machine of the operator's"; fails=$((fails + 1))
      fi
      # An address in a comment is someone's live host; in config it is the
      # value that has to be there (a resolver, a trusted-proxy range).
      while read -r ip; do
        [ -n "$ip" ] || continue
        is_private_ip "$ip" && continue
        finding HOST "$f" "$n" "names the live address $ip"; fails=$((fails + 1))
      done < <(grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' <<<"$line" | sort -u)
    fi
  done <"$f"
done

# Second pass: markdown. A doc describes the steady state; anything outstanding
# is an issue, not a paragraph.
for f in $(git ls-files '*.md'); do
  case "$f" in
    docs/AGENTS.md|.github/pull_request_template.md|.github/ISSUE_TEMPLATE/*) continue ;;
  esac
  n=0
  while IFS= read -r line; do
    n=$((n + 1))
    # A task shape, not the word: "an error is pending" is behaviour, "Pending:"
    # is somebody's open item.
    if [[ $line =~ (^|[^[:alnum:]_])(TODO|TBD|FIXME|WIP|awaiting)([^[:alnum:]_]|$) ]] \
       || [[ $line =~ [Pp]ending:[[:space:]] ]] \
       || [[ $line =~ pending[[:space:]]+(operator|task|work|decision|item|action) ]] \
       || [[ $line =~ ^[[:space:]]*-[[:space:]]\[[[:space:]]\] ]]; then
      finding PENDING "$f" "$n" "records an outstanding task or state"; fails=$((fails + 1))
    fi
  done <"$f"
done

if [ "$fails" -eq 0 ]; then
  echo "prose-audit: clean — comments describe the current configuration only"
  exit 0
fi

echo "prose-audit: $fails finding(s) — see AGENTS rule 31. Describe what runs now:"
echo "  no docs/ path (the doc says where it is), no size or duration measured on"
echo "  one host, no other machine or its address, no plan or guess."
[ "${PROSE_AUDIT_OVERRIDE:-}" = 1 ] && exit 0
exit 1
