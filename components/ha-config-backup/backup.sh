#!/bin/sh
# Mirrors a WHITELIST of Home Assistant config files from /config (read-only) to Git.
# Never copied: secrets.yaml, .storage/ (tokens, credentials) except Broadlink learnt
# codes, databases, logs, recordings.
set -eu

REPO="git@github.com:eduardolivenza/home-assistant.git"
BRANCH="main"
WORK="/tmp/repo"

log() { echo "$(date '+%H:%M:%S') $*"; }

log "Installing git, openssh"
apk add --no-cache git openssh-client >/dev/null

# SSH: deploy key from the SealedSecret + GitHub's published ed25519 host key (no TOFU).
# BatchMode: never wait for a prompt. ConnectTimeout: fail fast if port 22 is unreachable.
mkdir -p ~/.ssh
cp /ssh/id_ed25519 ~/.ssh/id_ed25519 && chmod 600 ~/.ssh/id_ed25519
echo "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl" > ~/.ssh/known_hosts
export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=10 -o ServerAliveCountMax=3"

git config --global user.name  "ha-config-backup"
git config --global user.email "ha-config-backup@asusold"
git config --global init.defaultBranch "$BRANCH"

log "Checking access to $REPO"
if ! REFS=$(timeout 60 git ls-remote "$REPO" 2>&1); then
  log "ERROR: cannot reach or authenticate to $REPO:"
  echo "$REFS"
  log "Check: deploy key added to the repo with 'Allow write access'; outbound SSH (port 22) to github.com."
  exit 1
fi

if echo "$REFS" | grep -q "refs/heads/$BRANCH"; then
  log "Cloning"
  git clone --quiet --depth 1 --branch "$BRANCH" "$REPO" "$WORK"
else
  log "Repo has no '$BRANCH' branch yet (first run): initialising"
  git init --quiet "$WORK"
  git -C "$WORK" remote add origin "$REPO"
fi

# Safety net inside the repo too, in case someone adds files by hand
cat > "$WORK/.gitignore" <<'IGN'
secrets.yaml
.storage/*
!.storage/broadlink_remote_*_codes
!.storage/broadlink_remote_*_flags
*.db
*.db-*
*.log
*.log.*
recordings/
IGN

log "Syncing whitelist from /config"
# Whitelist sync with plain rm + cp in this single process. rsync (forked
# sender/receiver) hung forever on this host after copying (2026-10-31), the same
# "process never woken up" symptom as PostgreSQL's io workers.
# Each item is removed from the repo and copied again if it still exists in HA,
# so deletions inside HA are mirrored too. Nothing outside the list is touched.
for item in configuration.yaml automations.yaml scripts.yaml scenes.yaml \
            customize.yaml groups.yaml .HA_VERSION \
            packages themes blueprints custom_templates; do
  rm -rf "${WORK:?}/$item"
  if [ -e "/config/$item" ]; then
    cp -a "/config/$item" "$WORK/$item"
  fi
done

# Broadlink IR/RF codes learnt with remote.learn_command live in .storage (which is
# otherwise never copied: it holds tokens). Only these files are mirrored.
rm -rf "${WORK:?}/.storage"
for f in /config/.storage/broadlink_remote_*_codes /config/.storage/broadlink_remote_*_flags; do
  [ -e "$f" ] || continue
  mkdir -p "$WORK/.storage"
  cp -a "$f" "$WORK/.storage/"
done

cd "$WORK"
log "Committing"
git add -A
if git diff --cached --quiet; then
  log "No changes"
  exit 0
fi
git commit --quiet -m "HA config $(date +%Y-%m-%d) (HA $(cat .HA_VERSION 2>/dev/null || echo '?'))"
log "Pushing"
timeout 120 git push --quiet origin "HEAD:$BRANCH"
log "Pushed:"
git show --stat --oneline HEAD | head -20
