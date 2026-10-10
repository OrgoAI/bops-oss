#!/usr/bin/env bash
# Deploys Bops Cloud to its box (orgo-web's production box, where it runs next to orgo-web): the code
# (cloud/, db/), its settings, and the orgo-relay rendezvous; then restarts both and checks the cloud
# answers. The box is set up once with cloud/deploy/install.sh. Run from the repo:
#   scripts/cloud-deploy.sh
# Needs: Orgo's private OrgoAI/bops-secrets next to this repo (BOPS_SECRETS points elsewhere) and sops,
# which decrypts its prod/bops-secrets.env; gh (fetches orgo-relay from its private releases); and SSH
# to the box as root (default key: z-legacy-fleet's id_ed25519; BOPS_CLOUD_SSH_KEY picks another).
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
cd "$root"
# Orgo's prod settings and secrets sit next to the main checkout (this may be a worktree elsewhere).
main="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"
prod="${BOPS_SECRETS:-$main/../bops-secrets}/prod"
[ -f "$prod/bops-public.env" ] || { echo "No $prod/bops-public.env: clone OrgoAI/bops-secrets next to $main, or set BOPS_SECRETS." >&2; exit 1; }
set -a
. "$prod/bops-public.env"
set +a
[ -f "$prod/bops-secrets.env" ] || { echo "No $prod/bops-secrets.env." >&2; exit 1; }
: "${BOPS_CLOUD_BOX:?set BOPS_CLOUD_BOX (root@<address>) in bops-secrets prod/bops-public.env}"

ssh_opts=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
key="${BOPS_CLOUD_SSH_KEY:-$root/../z-legacy-fleet/.ssh/id_ed25519}"
[ -f "$key" ] && ssh_opts+=(-i "$key" -o IdentitiesOnly=yes)
box() { ssh "${ssh_opts[@]}" "$BOPS_CLOUD_BOX" "$@"; }

if [ -n "$(git status --porcelain -- cloud db)" ]; then
  echo "cloud/ or db/ has uncommitted changes: commit them first, so the box runs a known version." >&2
  exit 1
fi
rev="$(git rev-parse --short HEAD)"

# Only what the cloud uses: the public settings above, and of the secrets only the provider keys,
# Slack's signing secret, the database and the sealing key (not Stripe, Latitude or the Orgo admin token).
# Both are read before anything on the box changes, so a decrypt that fails stops here.
public_settings="$(grep -E '^(BOPS_CLOUD_PUBLIC_URL|BOPS_CLOUD_PORT|BOPS_ORGO_ORIGIN|OPENAI_SIP_URI|BOPS_VERIFY_EMAIL|BOPS_SLACK_APP_ID|BOPS_COMPOSIO_AUTH_CONFIGS|BOPS_AI_CREDITS|BOPS_PLAN_LIMITS|BOPS_MAIL_DOMAIN|BOPS_PHONE_AREA|BOPS_TELEMETRY)=' "$prod/bops-public.env")"
secret_settings="$(sops -d "$prod/bops-secrets.env" | grep -E '^(BOPS_DATABASE_URL|BOPS_CLOUD_SECRET|OPENAI_API_KEY|OPENAI_EXECUTOR_API_KEY|OPENAI_WEBHOOK_SECRET|DEEPINFRA_API_KEY|AGENTPHONE_API_KEY|AGENTMAIL_API_KEY|HONCHO_API_KEY|COMPOSIO_API_KEY|TYPESAFE_API_KEY|TREG_TOKEN|BOPS_SLACK_SIGNING_SECRET|BOPS_CLOUD_PLAN_SECRET|TWILIO_[A-Z_]+)=')"
grep -q '^BOPS_DATABASE_URL=' <<<"$secret_settings" || { echo "No BOPS_DATABASE_URL in $prod/bops-secrets.env: the box's settings stay as they are." >&2; exit 1; }

echo "1/4 code ($rev)"
rsync -az --delete -e "ssh ${ssh_opts[*]}" --exclude node_modules --exclude test cloud db "$BOPS_CLOUD_BOX:/opt/bops/"
echo "$rev" | box 'cat > /opt/bops/REVISION'
box 'cd /opt/bops/cloud && npm install --omit=dev --no-audit --no-fund --no-package-lock --loglevel=error >/dev/null'

echo "2/4 settings"
printf '%s\n%s\n' "$public_settings" "$secret_settings" | box 'install -m 0640 -o root -g bops /dev/stdin /etc/bops-cloud/env'
unset secret_settings

echo "3/4 relay ($ORGO_RELAY_VERSION)"
scripts/relay-deploy.sh

echo "4/4 restart and check"
box 'systemctl restart bops-cloud.service && sleep 3 && systemctl is-active bops-cloud.service'
curl -fsS --retry 5 --retry-delay 2 --retry-all-errors "$BOPS_CLOUD_PUBLIC_URL/health"
echo
echo "Bops Cloud $rev is live at $BOPS_CLOUD_PUBLIC_URL"
