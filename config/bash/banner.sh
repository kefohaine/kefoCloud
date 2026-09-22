# root@{{HOSTNAME}} — terminal banner + prompt.
# Installed to /etc/kefo-banner.sh and sourced from ~/.bashrc by
# `make install-config`. Interactive shells only: scripts, scp, rsync and cron
# are never touched (non-interactive bash does not source ~/.bashrc anyway).
case $- in
  *i*) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac

PS1='\[\e[1;32m\]root@{{HOSTNAME}}\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '

cat <<'BANNER'

  ╭──────────────────────────────────────────────────────────────╮
  │  root@{{HOSTNAME}} · {{DOMAIN}} {{HOSTNAME}} · Debian 13             │
  ╰──────────────────────────────────────────────────────────────╯
   cloud  vault  kuma  mail  talk  www        dashboard: https://tail.{{DOMAIN}}
   make help · make help-more · make smoke · make dok-logs-<ctn>

BANNER
