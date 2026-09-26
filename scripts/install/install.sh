      done
    fi
  fi
}
trap summary EXIT

# ─────────────────────────────── main ──────────────────────────────────────

# A previous, incomplete run leaves either the saved answers (setup.state) or the
# instance.conf a run writes once the prompts are answered.
previous_install() { [ -s "${STATE:-}" ] || [ -s "$DATA/instance.conf" ]; }

main() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: root@$NODE_NAME is the only entry point (no sudo hand-off)."; exit 1
  fi
  ensure_runtime_dirs       # first: the prompts below log (see the helper)
  banner
  load_state
  if previous_install; then
    echo ""
    echo "A previous installation was detected."
    read -rp "Do you want to resume the previous installation? [Y/n]: " _resume || _resume=""
    case "${_resume,,}" in
      n|no)
        echo "Starting fresh — every prompt will be asked again (saved answers dropped)."
        unset DOMAIN CF_API_TOKEN TS_AUTHKEY TS_IP \
              MOD_CLOUD MOD_VAULT MOD_MAIL MOD_MONITOR GH_REMOTE
        rm -f "$STATE" "$DATA/instance.conf"
        ;;
      *)
        echo "Resuming — only values that are still missing get asked."
        ;;
    esac
  else
    # No previous run: drop whatever instance.sh's fallbacks put in the
    # environment (notably DOMAIN=example.com) so no prompt is silently skipped.
    unset DOMAIN CF_API_TOKEN TS_AUTHKEY
  fi
  ask_inputs
  save_state

  github_access
  write_instance_conf
  phase_host
  phase_stack
  resolve_errors
}

main "$@"
[Output exceeded 50000 byte limit (84961 bytes total). Full output saved to /tmp/.tmpZXHLSa/stdout-4. Read it with shell commands like `head`, `tail`, or `sed -n '100,200p'` up to 2000 lines at a time.]
[Output exceeded 50000 byte limit (84961 bytes total). Full output saved to /tmp/.tmpZXHLSa/output-4. Read it with shell commands like `head`, `tail`, or `sed -n '100,200p'` up to 2000 lines at a time.]
# Execute split phase scripts sequentially
for f in "$(dirname "$0")/phases/phase_*.sh"; do
  [ -x "$f" ] && . "$f" || { echo "Failed $f"; exit 1; }
done
