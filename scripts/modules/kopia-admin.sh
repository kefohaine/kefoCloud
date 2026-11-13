#!/usr/bin/env bash
# scripts/modules/kopia-admin.sh — repository and snapshots for the Kopia
# module, through the kopia CLI inside its own container.
#
#   kopia-admin.sh status                 container, repository, snapshots
#   kopia-admin.sh init                   connect the repository on external backup storage and set
#                                         its retention policy (idempotent)
#   kopia-admin.sh snapshot [<source>]    snapshot a source (default: the read-only mount)
#   kopia-admin.sh restore <id> [<dir>]   restore one snapshot into an empty
#                                         directory (default: <data>/restore)
#   kopia-admin.sh snapshots              list snapshots
#   kopia-admin.sh stats                  repository size on disk + content histogram
#   kopia-admin.sh maint-info             maintenance schedule/owner/next run
#   kopia-admin.sh maint-owner            claim maintenance for this host, so
#                                         kopia runs quick passes by itself
#                                         (needs CONFIRM=yes: it is background
#                                         work on the disk)
#   kopia-admin.sh maint [full]           run maintenance now (needs CONFIRM=yes;
#                                         full = re-pack + drop unreferenced)
#   kopia-admin.sh expire <id>            let retention drop one snapshot
#   kopia-admin.sh delete <id>            delete one snapshot immediately
#   kopia-admin.sh cli <args...>          any other kopia subcommand, unwrapped
#   kopia-admin.sh policy [<target>]      show the policy for a source
#   kopia-admin.sh ignore-add <pat> [<t>] add an ignore rule (path from the
#                                         source root) to a source's policy
#   kopia-admin.sh ignore-rm <pat> [<t>]  drop an ignore rule
#   kopia-admin.sh verify [<percent>]     verify a sample of stored packs
#   kopia-admin.sh logs [<lines>]         tail the container
#
# There is no server in this module: no UI account, no API, no listener. The
# repository lives on external backup storage and is reached over SFTP on the tailnet;
# its location and identity come from KOPIA_SFTP_* in data/instance.conf.
#
# Any of these accepts --dry-run (or DRYRUN=1) to print the plan instead of
# writing; status/snapshots/logs are read-only and run normally either way.
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/instance.sh"
. "$(dirname "$(readlink -f "$0")")/../lib/dryrun.sh"
. "$(dirname "$(readlink -f "$0")")/../lib/modules.sh"
. "$(dirname "$(readlink -f "$0")")/../lib/kopia-env.sh"

ENV="$REPO_DIR/modules/kopia/.env"
[ -f "$ENV" ] || { echo "kopia-admin: $ENV is missing — run 'make kopia-gen'" >&2; exit 1; }
# shellcheck disable=SC1090
. "$ENV"

PORT="${KOPIA_SFTP_PORT:-22}"
kopia_live || { echo "kopia-admin: container '$(mod_containers kopia)' is absent — run 'make dok-recreate-kopia' first" >&2; exit 1; }
CONF="$KOPIA_CONFIG" KEY="$KOPIA_KEY" KNOWN="$KOPIA_KNOWN" SRC="$KOPIA_SOURCE"
HOST_ID="$(kopia_host)"

dryrun_wanted "$@" && DRY=1
dryrun_args "$@"; set -- "${DRYRUN_ARGS[@]}"
die() { printf 'kopia-admin: %s\n' "$*" >&2; exit 1; }
# Every kopia call is time-bounded inside the container, so a wedged SFTP session
# dies on its own instead of holding the disk busy: reads get KOPIA_TIMEOUT (60 s),
# mutations KOPIA_LONG_TIMEOUT (300 s), and a snapshot opts out with
# KOPIA_BUDGET=0 because it legitimately uploads for a long time.
kopia() {
  local budget="${KOPIA_BUDGET:-${KOPIA_LONG_TIMEOUT:-300}}"
  if [ "$budget" = 0 ]; then
    docker exec -e KOPIA_PASSWORD="$KOPIA_PASSWORD" "$KOPIA_CTN" \
      kopia --config-file="$CONF" "$@"
  else
    docker exec -e KOPIA_PASSWORD="$KOPIA_PASSWORD" "$KOPIA_CTN" \
      timeout "$budget" kopia --config-file="$CONF" "$@"
  fi
}
connected() { KOPIA_BUDGET="${KOPIA_TIMEOUT:-60}" kopia repository status >/dev/null 2>&1; }
# The identity kopia recorded for this config — user@hostname.
repo_identity() { KOPIA_BUDGET="${KOPIA_TIMEOUT:-60}" kopia repository status 2>/dev/null | sed -n 's/^Hostname: *//p;'; }
sftp_flags() {
  printf '%s\n' --path="$KOPIA_SFTP_PATH" --host="$KOPIA_SFTP_HOST" --port="$PORT" \
    --username="$KOPIA_SFTP_USER" --keyfile="$KEY" --known-hosts="$KNOWN"
}

case "${1:-status}" in
  status)
    docker ps -a --filter "name=^${KOPIA_CTN}$" --format '  {{.Names}}\t{{.Status}}'
    if connected; then
      kopia repository status
      kopia snapshot list --all 2>/dev/null | tail -20 || true
    else
      echo "  repository: not connected (run 'make kopia-init')" >&2
      exit 1
    fi
    ;;

  init)
    for v in KOPIA_SFTP_HOST KOPIA_SFTP_USER KOPIA_SFTP_PATH; do
      [ -n "${!v:-}" ] || die "$v is empty — set it in $DATA_DIR/instance.conf, then run 'make render'"
    done
    if [ "${DRY:-0}" = 1 ]; then
      [ -s "$DATA_DIR/kopia/ssh/known_hosts" ] || dryrun_plan "pin the host key of $KOPIA_SFTP_HOST:$PORT into $KNOWN (ssh-keyscan)"
      connected || dryrun_plan "create an sftp repository at $KOPIA_SFTP_USER@$KOPIA_SFTP_HOST:$KOPIA_SFTP_PATH and connect $CONF to it"
      dryrun_plan "set the global retention policy (${KOPIA_KEEP_LATEST:-10} latest, ${KOPIA_KEEP_DAILY:-14} daily, ${KOPIA_KEEP_WEEKLY:-8} weekly, ${KOPIA_KEEP_MONTHLY:-12} monthly)"
      dryrun_end
    fi
    if [ ! -s "$DATA_DIR/kopia/ssh/known_hosts" ]; then
      command -v ssh-keyscan >/dev/null 2>&1 \
        || die "ssh-keyscan is missing — install openssh-client, or write the host key into $KNOWN"
      ssh-keyscan -p "$PORT" "$KOPIA_SFTP_HOST" >"$DATA_DIR/kopia/ssh/known_hosts" 2>/dev/null
      [ -s "$DATA_DIR/kopia/ssh/known_hosts" ] \
        || die "cannot reach $KOPIA_SFTP_HOST:$PORT — is that machine awake and on the tailnet?"
      echo "kopia-admin: pinned the host key of $KOPIA_SFTP_HOST:$PORT"
    fi
    # The recorded identity must match this container, or maintenance (and
    # retention) silently stops being this host's job. --override-hostname pins it
    # to the container's configured hostname instead of a throwaway container id.
    mapfile -t SFTP < <(sftp_flags)
    if connected && [ -n "${HOST_ID:-}" ] && [ "$(repo_identity)" = "$HOST_ID" ]; then
      echo "kopia-admin: already connected as $(repo_identity) — leaving it alone"
    elif connected; then
      kopia repository connect sftp "${SFTP[@]}" --override-hostname="$HOST_ID" \
        || die "repository reconnect failed"
      echo "kopia-admin: reconnected as $HOST_ID (was $(repo_identity))"
    else
      kopia repository create sftp "${SFTP[@]}" --override-hostname="$HOST_ID" \
        || die "repository create failed — is the disk mounted at $KOPIA_SFTP_PATH and this key authorized there?"
      echo "kopia-admin: repository created at $KOPIA_SFTP_USER@$KOPIA_SFTP_HOST:$KOPIA_SFTP_PATH"
    fi
    # Maintenance is left unclaimed here on purpose. Claiming it makes kopia run
    # a quick maintenance pass by itself after every snapshot, which is background
    # work on the backup disk nobody asked for. `make kopia-maint-owner` claims it
    # explicitly; until then the repository only grows by what snapshots add.
    kopia policy set --global \
      --keep-latest="${KOPIA_KEEP_LATEST:-10}" \
      --keep-daily="${KOPIA_KEEP_DAILY:-14}" \
      --keep-weekly="${KOPIA_KEEP_WEEKLY:-8}" \
      --keep-monthly="${KOPIA_KEEP_MONTHLY:-12}" \
      || die "retention policy could not be set"
    # The source tree holds kopia's own state too; ignoring it keeps a snapshot
    # from crawling into the backup's own config, key and cache.
    if [ -n "$KOPIA_SELF" ]; then
      kopia policy set "$SRC" --add-ignore="$KOPIA_SELF" \
        || die "source ignore policy could not be set"
    fi
    ;;

  snapshot)
    if [ "${DRY:-0}" = 1 ]; then
      dryrun_plan "snapshot ${2:-$SRC} into the repository on external backup storage through the kopia container"
      dryrun_end
    fi
    # Same lock the timer takes: a manual run waits for a running window instead
    # of starting a second, overlapping snapshot of the same source.
    kopia_lock -w 3600 || die "another snapshot is still running — see 'make kopia-status'"
    KOPIA_BUDGET="${KOPIA_SNAPSHOT_TIMEOUT:-0}" kopia snapshot create "${2:-$SRC}" \
      || die "snapshot failed"
    ;;

  policy)
    kopia policy show "${2:-$SRC}" || die "policy could not be read"
    ;;

  ignore-add|ignore-rm)
    [ -n "${2:-}" ] || die "usage: kopia-admin.sh $1 <pattern> [<source>]"
    flag=--add-ignore
    [ "$1" = ignore-rm ] && flag=--remove-ignore
    kopia policy set "${3:-$SRC}" "$flag=$2" || die "policy update failed"
    ;;

  restore)
    [ -n "${2:-}" ] || die "usage: kopia-admin.sh restore <snapshot-id> [<dir>]"
    TGT="${3:-$KOPIA_DATA/restore}"
    if [ "${DRY:-0}" = 1 ]; then
      dryrun_plan "restore snapshot $2 into $TGT inside $KOPIA_CTN"
      dryrun_end
    fi
    # A restore into a populated directory would silently overwrite files that
    # are not part of the snapshot; refuse instead of guessing.
    if docker exec "$KOPIA_CTN" sh -c "test -d '$TGT' && [ -n \"\$(ls -A '$TGT')\" ]" 2>/dev/null; then
      die "$TGT is not empty — restore into an empty directory"
    fi
    kopia_lock -w 3600 || die "another snapshot or restore is still running"
    docker exec "$KOPIA_CTN" mkdir -p "$TGT"
    kopia snapshot restore "$2" "$TGT" || die "restore failed"
    echo "kopia-admin: restored snapshot $2 into $KOPIA_CTN:$TGT"
    ;;

  stats)
    # Bytes come from the disk itself: kopia's whole-repo enumeration
    # (`blob stats`, a full `blob list`) stalls on this SFTP transport and never
    # returns, so it is not used here.
    vol="$(kopia_volume 2>/dev/null)" || vol=""
    if [ -n "$vol" ] && kopia_ssh "du -sh '$KOPIA_SFTP_PATH'" >/dev/null 2>&1; then
      dev=${vol%%|*}; rest=${vol#*|}; mnt=${rest%%|*}
      echo "  repository directory: $(kopia_ssh "du -sh '$KOPIA_SFTP_PATH'")"
      awk -v d="$dev" -v m="$mnt" -v v="$vol" 'BEGIN{
        n=split(v,a,"|"); gib=1024*1024
        printf "  volume: %s at %s — %.1f GiB used of %.1f GiB (%.1f GiB free)\n",
          d, m, a[4]/gib, a[3]/gib, a[5]/gib }'
      if [ "$dev" = "$(kopia_rootdev 2>/dev/null)" ]; then
        echo "  WARNING: $KOPIA_SFTP_PATH is on the host's main volume, not a separate backup volume"
      fi
    else
      echo "  repository directory: unreachable (host asleep, volume unplugged, or off the tailnet)"
      exit 0
    fi
    echo
    kopia content stats
    ;;

  maint-info)
    kopia maintenance info
    ;;

  maint-owner)
    [ "${CONFIRM:-no}" = yes ] \
      || die "claiming maintenance makes kopia run unattended passes on the backup disk — re-run with CONFIRM=yes"
    kopia maintenance set --owner="root@$(kopia_host)" --enable-quick=true >/dev/null 2>&1 \
      || die "could not claim maintenance ownership"
    echo "kopia-admin: maintenance owner is now root@$(kopia_host) (quick passes enabled)"
    ;;

  maint)
    [ "${CONFIRM:-no}" = yes ] \
      || die "maintenance rewrites and deletes blobs on the backup disk — re-run with CONFIRM=yes"
    FULL=""
    [ "${2:-}" = full ] && FULL="--full"
    # A full pass is the heaviest thing this module can do; it is bounded only by
    # its own progress output and must be watched, never scheduled.
    KOPIA_BUDGET=0 kopia maintenance run $FULL 2>&1 | tail -5 \
      || die "maintenance failed — is an owner set ('make kopia-maint-owner CONFIRM=yes')?"
    ;;

  expire)
    [ -n "${2:-}" ] || die "usage: kopia-admin.sh expire <snapshot-id>"
    kopia snapshot expire "$2"
    ;;

  delete)
    [ -n "${2:-}" ] || die "usage: kopia-admin.sh delete <snapshot-id>"
    kopia snapshot delete --delete "$2" || die "delete failed"
    ;;

  cli)
    shift
    [ "$#" -gt 0 ] || die "usage: kopia-admin.sh cli <kopia subcommand...>"
    kopia "$@"
    ;;

  snapshots)
    kopia snapshot list --all
    ;;

  verify)
    if [ "${DRY:-0}" = 1 ]; then
      dryrun_plan "re-read ${2:-5}% of the stored packs from the repository and verify their hashes"
      dryrun_end
    fi
    KOPIA_BUDGET=0 kopia snapshot verify --verify-files-percent="${2:-5}"
    ;;

  logs)
    docker logs kopia --tail "${2:-50}" -f
    ;;

  *)
    die "usage: kopia-admin.sh status|init|snapshot|snapshots|verify|logs"
    ;;
esac
