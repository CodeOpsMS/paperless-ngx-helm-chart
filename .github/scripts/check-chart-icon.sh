#!/usr/bin/env bash

set -euo pipefail

chart_ref="${1:-.}"
icon_url="$(helm show chart "$chart_ref" | awk '/^icon:/ { print $2 }')"
expected_icon_url="https://raw.githubusercontent.com/paperless-ngx/paperless-ngx/main/docs/assets/logo_leaf.svg"

if [[ -z "$icon_url" ]]; then
  echo "::error::Chart metadata does not define an icon URL"
  exit 1
fi

if [[ "$icon_url" != "$expected_icon_url" ]]; then
  echo "::error::Chart icon must use the stable upstream URL: $expected_icon_url"
  exit 1
fi

case "$icon_url" in
  https://*) ;;
  *)
    echo "::error::Chart icon must use HTTPS: $icon_url"
    exit 1
    ;;
esac

icon_file="$(mktemp)"
cleanup() {
  rm -f "$icon_file"
}
trap cleanup EXIT

content_type="$(curl \
  --fail \
  --silent \
  --show-error \
  --location \
  --retry 3 \
  --retry-delay 2 \
  --output "$icon_file" \
  --write-out '%{content_type}' \
  "$icon_url")"

if [[ ! -s "$icon_file" ]]; then
  echo "::error::Chart icon response is empty: $icon_url"
  exit 1
fi

normalized_content_type="$(printf '%s' "$content_type" | tr '[:upper:]' '[:lower:]')"
case "$normalized_content_type" in
  image/svg+xml* | image/png* | image/jpeg* | image/webp*) ;;
  *)
    echo "::error::Chart icon returned an unsupported content type: ${content_type:-missing}"
    exit 1
    ;;
esac

echo "Chart icon is reachable: $icon_url ($content_type)"
