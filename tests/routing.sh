#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT_DIR/install-reality.sh"
TEST_DIR=$(mktemp -d /tmp/reality-routing-test.XXXXXXXX)
trap 'rm -rf -- "$TEST_DIR"' EXIT
printf '%s\n' '{"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}],"routing":{"rules":[{"type":"field","domain":["domain:example.org"],"outboundTag":"direct"}]}}' > "$TEST_DIR/base.json"
jq '.routing.rules += [{type:"field",outboundTag:"warp",domain:["domain:grok.com"]}]' "$TEST_DIR/base.json" > "$TEST_DIR/old-routes.json"
add_routes "$TEST_DIR/old-routes.json" "$TEST_DIR/first.json"
add_routes "$TEST_DIR/first.json" "$TEST_DIR/second.json"
cmp "$TEST_DIR/first.json" "$TEST_DIR/second.json"
jq -e '
  .outbounds[0].tag == "direct"
  and ([.outbounds[] | select(.tag == "warp")] | length == 1)
  and .routing.rules[1].domain == ["domain:example.org"]
  and (.routing.rules | length == 2)
  and .routing.rules[0].outboundTag == "warp"
  and (.routing.rules[0].domain | length == 8)
  and (.routing.rules[0].domain | index("domain:leetcode.com") != null)
  and (.routing.rules[0].domain | index("domain:grok.com") != null)
' "$TEST_DIR/second.json" >/dev/null
jq '.outbounds += [{tag:"warp",protocol:"freedom"}]' "$TEST_DIR/base.json" > "$TEST_DIR/conflict.json"
if add_routes "$TEST_DIR/conflict.json" "$TEST_DIR/rejected.json" 2>/dev/null; then
    echo 'FAIL: conflicting warp outbound accepted' >&2
    exit 1
fi
printf 'Routing tests passed.\n'
