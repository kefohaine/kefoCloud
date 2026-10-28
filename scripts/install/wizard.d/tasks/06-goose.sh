# wizard.d/tasks/06-goose.sh — `Goose CLI`: the agent tool and its instance env file.

# Goose CLI: install the agent binary (needs the bzip2 apt dep above).
task_goose() {
  task_start
  if ! command -v goose >/dev/null 2>&1 && [ ! -x /usr/local/bin/goose ]; then
    # Official installer (release archive, .tar.bz2 — hence the bzip2 apt dep
    # above). Output goes to the log, so a failure is diagnosable.
    curl -fsSL https://github.com/aaif-goose/goose/releases/download/stable/download_cli.sh \
      | CONFIGURE=false GOOSE_BIN_DIR=/usr/local/bin bash >>"$LOG" 2>&1 || true
  fi
  if command -v goose >/dev/null 2>&1; then
    # Only copy when goose lives elsewhere: `install` onto the same path prints
    # "install: 'x' and 'x' are the same file" and exits 1.
    [ "$(command -v goose)" = "/usr/local/bin/goose" ] \
      || install -m 0755 "$(command -v goose)" /usr/local/bin/goose || true
  elif [ -x "$HOME/.local/bin/goose" ]; then
    install -m 0755 "$HOME/.local/bin/goose" /usr/local/bin/goose || true
  fi
  command -v goose >/dev/null 2>&1 || [ -x /usr/local/bin/goose ] || fail goose
  task_end
}
