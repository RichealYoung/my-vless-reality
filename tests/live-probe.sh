#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# == 1 ]] || { echo 'Usage: bash tests/live-probe.sh SERVER_IP' >&2; exit 1; }
SERVER_IP=$1
TEST_DIR=$(mktemp -d /tmp/reality-live-probe.XXXXXXXX)
PROBE_PID=''
cleanup() {
    [[ -z "$PROBE_PID" ]] || { kill "$PROBE_PID" 2>/dev/null || true; wait "$PROBE_PID" 2>/dev/null || true; }
    rm -rf -- "$TEST_DIR"
}
trap cleanup EXIT
umask 077
[[ -z "$(ss -H -ltn 'sport = :41081')" ]] || { echo 'Test port occupied' >&2; exit 1; }
PUBLIC_KEY=$(sed -n 's/.*[?&]pbk=\([^&]*\).*/\1/p' /root/vless-reality-link.txt)
[[ "$PUBLIC_KEY" =~ ^[A-Za-z0-9_-]{43}$ ]]
jq --arg host "$SERVER_IP" --arg key "$PUBLIC_KEY" '
  .inbounds[] | select(.tag=="vless-reality-in") | . as $server |
  {log:{loglevel:"warning"},
   inbounds:[{listen:"127.0.0.1",port:41081,protocol:"socks",settings:{auth:"noauth",udp:false}}],
   outbounds:[{protocol:"vless",settings:{vnext:[{address:$host,port:$server.port,users:[{id:$server.settings.clients[0].id,encryption:"none",flow:"xtls-rprx-vision"}]}]},
     streamSettings:{network:"tcp",security:"reality",realitySettings:{serverName:$server.streamSettings.realitySettings.serverNames[0],fingerprint:"chrome",publicKey:$key,shortId:$server.streamSettings.realitySettings.shortIds[0]}}}]}
' /usr/local/etc/xray/config.json > "$TEST_DIR/client.json"
/usr/local/bin/xray run -config "$TEST_DIR/client.json" > "$TEST_DIR/probe.log" 2>&1 &
PROBE_PID=$!
sleep 1
for host in grok.com leetcode.com; do
    curl --noproxy '' --proxy socks5h://127.0.0.1:41081 --connect-timeout 10 --max-time 25 -sS -o /dev/null -w "$host HTTP %{http_code}\n" "https://$host/"
done
printf 'Default outbound trace:\n'
curl --noproxy '' --proxy socks5h://127.0.0.1:41081 --connect-timeout 10 --max-time 25 -fsS https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|warp)='
sleep 1
printf 'Live server routing evidence:\n'
tail -n 60 /var/log/xray/access.log | grep -E '(grok.com|leetcode.com).*\[vless-reality-in -> warp\]' | tail -n 4
systemctl is-active xray warp-svc
