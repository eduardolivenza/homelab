#!/bin/sh
# Mirrors a WHITELIST of Home Assistant config files from /config (read-only) to Git.
# Never copied: secrets.yaml, .storage/ (tokens, credentials), databases, logs, recordings.
set -eu

REPO="git@github.com:eduardolivenza/home-assistant.git"
BRANCH="main"
WORK="/tmp/repo"

apk add --no-cache git openssh-client rsync >/dev/null

# SSH: deploy key from the SealedSecret + GitHub's published ed25519 host key (no TOFU)
mkdir -p ~/.ssh
cp /ssh/id_ed25519 ~/.ssh/id_ed25519 && chmod 600 ~/.ssh/id_ed25519
echo "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl" > ~/.ssh/known_hosts

git config --global user.name  "ha-config-backup"
git config --global user.email "ha-config-backup@asusold"
git config --global init.defaultBranch "$BRANCH"

if git clone --quiet --depth 1 --branch "$BRANCH" "$REPO" "$WORK" 2>/dev/null; then
  echo "Cloned $REPO"
else
  echo "Empty repo (first run): initialising"
  git init --quiet "$WORK"
  git -C "$WORK" remote add origin "$REPO"
fi

# Safety net inside the repo too, in case someone adds files by hand
cat > "$WORK/.gitignore" <<'IGN'
secrets.yaml
.storage/
*.db
*.db-*
*.log
*.log.*
recordings/
IGN

# Whitelist sync. P = protect from --delete (repo-only files).
rsync -a --checksum --delete \
  --filter='P /.git' --filter='P /.gitignore' --filter='P /README.md' \
  --include='/configuration.yaml' \
  --include='/automations.yaml' \
  --include='/scripts.yaml' \
  --include='/scenes.yaml' \
  --include='/customize.yaml' \
  --include='/groups.yaml' \
  --include='/.HA_VERSION' \
  --include='/packages/***' \
  --include='/themes/***' \
  --include='/blueprints/***' \
  --include='/custom_templates/***' \
  --exclude='*' \
  /config/ "$WORK/"

cd "$WORK"
git add -A
if git diff --cached --quiet; then
  echo "No changes"
  exit 0
fi
git commit --quiet -m "HA config $(date +%Y-%m-%d) (HA $(cat .HA_VERSION 2>/dev/null || echo '?'))"
git push --quiet origin "HEAD:$BRANCH"
echo "Pushed:"
git show --stat --oneline HEAD | head -20
