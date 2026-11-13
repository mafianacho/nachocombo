#!/bin/bash
# Posts a published GitHub Release (link + details) to a Discord channel webhook.
#
# Usage (CI):  TAG=v0.8.0 GITHUB_REPOSITORY=owner/repo GH_TOKEN=... DISCORD_WEBHOOK=... \
#              scripts/notify-discord-release.sh
# Optional:    RUN_URL=<workflow run url>   adds a link to the build run
#              DRY_RUN=1                    prints the JSON payload instead of posting
#
# DISCORD_WEBHOOK must come from an Actions *secret*: secrets are masked in logs, repository
# variables are not, and this repository's logs are public. When it is empty the script only
# prints a notice and exits 0, so a release never fails for want of a webhook.
set -euo pipefail

TAG="${TAG:?set TAG, e.g. TAG=v0.8.0}"
REPO="${GITHUB_REPOSITORY:?set GITHUB_REPOSITORY, e.g. mafianacho/nachocombo}"
RUN_URL="${RUN_URL:-}"
DRY_RUN="${DRY_RUN:-}"
WEBHOOK="${DISCORD_WEBHOOK:-}"

if [ -z "$WEBHOOK" ] && [ -z "$DRY_RUN" ]; then
  echo "::notice::DISCORD_DEPLOY_WEBHOOK secret is not set; skipping the Discord release message."
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

gh api "repos/$REPO/releases/tags/$TAG" > "$work/release.json"
commit="$(gh api "repos/$REPO/commits/$TAG" --jq .sha)"

# Discord limits: embed description 4096, field value 1024, whole embed 6000 characters.
jq -n \
  --slurpfile rel "$work/release.json" \
  --arg repo "$REPO" \
  --arg tag "$TAG" \
  --arg commit "$commit" \
  --arg run_url "$RUN_URL" '
  ($rel[0]) as $r
  | def mb: (. / 1048576 * 10 | round / 10 | tostring) + " MB";
    def clip($n): if length > $n then .[0:$n] + "…" else . end;
    def kst: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 + 9 * 3600 | strftime("%Y-%m-%d %H:%M KST");
    ($r.body // "" | gsub("\r"; "")) as $body
  | ($r.assets | map(select(.name | test("\\.(zip|dmg)$")))) as $bins
  | ($r.assets | map(select(.name | test("SHA256SUMS"))) | first) as $sums
  | {
      username: "Nacho Combo Release",
      allowed_mentions: { parse: [] },
      content: "🚀 **\($r.name // $tag)** 배포 완료\n\($r.html_url)",
      embeds: [{
        title: ($r.name // $tag) | clip(250),
        url: $r.html_url,
        color: 16753920,
        description: (if ($body | length) > 3500
          then $body[0:3500] + "…\n\n(전체 노트는 릴리즈 페이지에서 확인)"
          else $body end),
        fields: ([
          { name: "버전", value: "`\($tag)`", inline: true },
          { name: "커밋", value: "[`\($commit[0:7])`](https://github.com/\($repo)/commit/\($commit))", inline: true },
          { name: "게시", value: ($r.published_at // $r.created_at | kst), inline: true },
          { name: "다운로드",
            value: ([ $bins[] | "[\(.name)](\(.browser_download_url)) (\(.size | mb))" ]
                    + (if $sums then [ "[\($sums.name)](\($sums.browser_download_url))" ] else [] end)
                    | join("\n") | if . == "" then "(첨부 없음)" else . end | clip(1000)),
            inline: false },
          { name: "SHA-256",
            value: ([ $bins[] | select(.digest) | "`\(.digest | sub("^sha256:"; ""))`  \(.name)" ]
                    | join("\n") | if . == "" then "(digest 없음)" else . end | clip(1000)),
            inline: false }
        ] + (if $run_url != "" then [ { name: "빌드", value: "[GitHub Actions 실행](\($run_url))", inline: false } ] else [] end)),
        footer: { text: $repo },
        timestamp: ($r.published_at // $r.created_at)
      }]
    }' > "$work/payload.json"

if [ -n "$DRY_RUN" ]; then
  cat "$work/payload.json"
  exit 0
fi

# ?wait=true makes Discord answer with the created message, so a rejected payload fails this step.
# curl -sS prints errors without the URL; the webhook itself is masked as a secret.
code="$(curl -sS -o "$work/response.json" -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  --data-binary @"$work/payload.json" \
  "$WEBHOOK?wait=true")"
if [ "${code:0:1}" != "2" ]; then
  echo "Discord webhook answered HTTP $code" >&2
  jq -c '{code, message, errors}' "$work/response.json" >&2 2>/dev/null || true
  exit 1
fi
echo "Discord release message posted (message id $(jq -r '.id // "?"' "$work/response.json"))."
