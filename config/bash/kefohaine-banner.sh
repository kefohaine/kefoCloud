# kefohaine@server — terminal banner + prompt.
# Installed to /etc/kefohaine-banner.sh and sourced from ~/.bashrc by
# `make install-config`. Interactive shells only: scripts, scp, rsync and cron
# are never touched (non-interactive bash does not source ~/.bashrc anyway).
case $- in
  *i*) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac

PS1='\[\e[1;32m\]kefohaine@server\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '

cat <<'BANNER'

  ╭──────────────────────────────────────────────────────────────╮
  │  kefohaine@server · fxmq.net homelab · Debian 13             │
  ╰──────────────────────────────────────────────────────────────╯
   cloud  vault  kuma  mail  mc  talk  www        dashboard: https://tail.fxmq.net
   make help · make list · make smoke · make dok-logs-<ctn>

BANNER
