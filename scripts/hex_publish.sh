#!/usr/bin/env bash
# Publish all Pincer packages to Hex.pm in dependency order.
# Run from the repo root: bash scripts/hex_publish.sh
# Requires: mix hex.user auth (run `mix hex.user auth` first)

set -euo pipefail

PACKAGES_DIR="$(cd "$(dirname "$0")/.." && pwd)/packages"

# Publication order: dependencies before dependents
PUBLISH_ORDER=(
  pincer_ports
  pincer_openai_compat
  pincer_anthropic
  pincer_google
  pincer_ollama
  pincer_groq
  pincer_minimax
  pincer_mistral
  pincer_moonshot
  pincer_openai
  pincer_openrouter
  pincer_deepseek
  pincer_qwen
  pincer_zhipu
  pincer_opencode_zen
  pincer_cli
  pincer_telegram
  pincer_webhook
  pincer_whatsapp
  pincer_line
  pincer_feishu
  pincer_dingtalk
  pincer_slack
  pincer_discord
)

DRY_RUN="${DRY_RUN:-false}"

for pkg in "${PUBLISH_ORDER[@]}"; do
  dir="$PACKAGES_DIR/$pkg"
  echo "==> Publishing $pkg..."
  if [ "$DRY_RUN" = "true" ]; then
    echo "    [DRY RUN] would run: mix hex.publish --yes in $dir"
  else
    (cd "$dir" && mix deps.get && mix hex.publish --yes)
    echo "    Published $pkg"
    # Brief pause to avoid rate limiting
    sleep 2
  fi
done

echo ""
echo "All packages published successfully."
