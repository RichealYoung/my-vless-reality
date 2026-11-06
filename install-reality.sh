#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

XRAY_VERSION="v26.9.9"
CONFIG=/usr/local/etc/xray/config.json
WARP_PORT=40000
PORT=443
SERVER_NAME=www.cloudflare.com
TMP_DIR=''
SERVICE_CREATED=0
SUCCESS=0
WARP_DOMAINS=(grok.com x.ai grok.x.com grokipedia.com leetcode.com leetcode.cn leetcode-cn.com leetcdn.cn)

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
x25519_field() {
    awk -F: -v kind="$2" '
      {
        label = tolower($1)
        gsub(/[^a-z]/, "", label)
        if ((kind == "private" && label == "privatekey") ||
            (kind == "public" && (label == "passwordpublickey" || label == "publickey" || label == "password"))) {
          value = $2
          gsub(/[[:space:]]/, "", value)
          print value
          exit
        }
      }
    ' <<< "$1"
}
cleanup() {
    local code=$?
    trap - EXIT
    if [[ "$SUCCESS" == 0 && "$SERVICE_CREATED" == 1 ]]; then
        systemctl disable --now xray >/dev/null 2>&1 || true
        printf 'Installation incomplete; Xray stopped. Files retained for diagnosis.\n' >&2
    fi
    [[ -z "$TMP_DIR" ]] || rm -rf -- "$TMP_DIR"
    exit "$code"
}

add_routes() {
    local domains
    domains=$(printf 'domain:%s\n' "${WARP_DOMAINS[@]}" | jq -R . | jq -s .)
    jq --argjson domains "$domains" --argjson port "$WARP_PORT" '
      def covered_rule:
        .type == "field" and .outboundTag == "warp"
        and (.domain | type) == "array"
        and ((keys - ["type","outboundTag","domain"]) | length) == 0
        and ((.domain - $domains) | length) == 0;
      if any(.outbounds[]; .tag == "warp") then
        if any(.outbounds[]; .tag == "warp" and .protocol == "socks" and .settings.servers[0].address == "127.0.0.1" and .settings.servers[0].port == $port)
        then . else error("Existing warp outbound uses different settings") end
      else .outbounds += [{tag:"warp",protocol:"socks",settings:{servers:[{address:"127.0.0.1",port:$port}]}}] end
      | .routing = (.routing // {})
      | .routing.rules = ([{type:"field",outboundTag:"warp",domain:$domains}] + [(.routing.rules // [])[] | select(covered_rule | not)])
    ' "$1" > "$2"
}

warp_ready() {
    local trace
    trace=$(curl --noproxy '' --proxy "socks5h://127.0.0.1:$WARP_PORT" -fsS --connect-timeout 5 --max-time 12 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null) || return 1
    grep -Eq '^warp=(on|plus)$' <<< "$trace"
}

setup_warp() {
    # Reuse an existing working local proxy without changing its registration/mode.
    if warp_ready; then
        systemctl enable warp-svc
        return
    fi
    if command -v warp-cli >/dev/null; then
        die 'Existing WARP is not working at 127.0.0.1:40000. Repair it first; existing settings were not changed.'
    fi
    [[ -z "$(ss -H -ltn 'sport = :40000')" ]] || die 'TCP 40000 is occupied.'
    curl -fsSL --retry 3 --max-time 60 https://pkg.cloudflareclient.com/pubkey.gpg -o "$TMP_DIR/warp-key.asc"
    gpg --batch --yes --dearmor --output "$TMP_DIR/warp-key.gpg" "$TMP_DIR/warp-key.asc"
    install -m 644 "$TMP_DIR/warp-key.gpg" /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    printf 'deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ %s main\n' "$VERSION_CODENAME" > /etc/apt/sources.list.d/cloudflare-client.list
    chmod 644 /etc/apt/sources.list.d/cloudflare-client.list
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y cloudflare-warp
    systemctl enable --now warp-svc
    local attempt
    for ((attempt=0; attempt<15; attempt++)); do
        if warp-cli --accept-tos status >/dev/null 2>&1; then break; fi
        sleep 1
    done
    if ! warp-cli --accept-tos registration show >/dev/null 2>&1; then
        warp-cli --accept-tos registration new
    fi
    # Set proxy mode before connecting so the server's SSH/default route is preserved.
    warp-cli --accept-tos mode proxy
    warp-cli --accept-tos proxy port "$WARP_PORT"
    warp-cli --accept-tos connect
    for ((attempt=0; attempt<10; attempt++)); do
        if warp_ready; then return; fi
        sleep 2
    done
    die 'WARP proxy did not become ready. Xray has not been installed.'
}

update_routes() {
    [[ -f "$CONFIG" ]] || die 'No existing Xray configuration was found.'
    command -v jq >/dev/null || die 'jq is required.'
    command -v curl >/dev/null || die 'curl is required.'
    warp_ready || die 'WARP proxy at 127.0.0.1:40000 is not ready.'
    local backup staged port
    backup="/root/xray-before-warp-update-$(date +%Y%m%d-%H%M%S)-$$.json"
    staged=$(mktemp --suffix=.json /usr/local/etc/xray/.warp-update.XXXXXXXX)
    cp -a "$CONFIG" "$backup"
    if ! add_routes "$CONFIG" "$staged" || ! /usr/local/bin/xray run -test -config "$staged"; then
        rm -f -- "$staged"
        die 'Validation failed; existing configuration is unchanged.'
    fi
    chown --reference="$CONFIG" "$staged"
    chmod --reference="$CONFIG" "$staged"
    mv -f -- "$staged" "$CONFIG"
    if ! systemctl restart xray; then
        cp -a "$backup" "$CONFIG"
        systemctl restart xray
        die 'Restart failed; restored backup.'
    fi
    sleep 2
    port=$(jq -r '.inbounds[] | select(.tag=="vless-reality-in") | .port' "$CONFIG")
    if ! systemctl is-active --quiet xray || { [[ -n "$port" ]] && [[ -z "$(ss -H -ltn "sport = :$port")" ]]; }; then
        cp -a "$backup" "$CONFIG"
        systemctl restart xray
        die 'Service verification failed; restored backup.'
    fi
    printf 'WARP routing updated. Backup: %s\n' "$backup"
}

install_xray() {
    local server_ip="${1:-}" asset uri_host expected actual base_url
    command -v apt-get >/dev/null || die 'Ubuntu/Debian with apt-get is required.'
    # shellcheck disable=SC1091
    source /etc/os-release
    case "${ID:-}:${VERSION_CODENAME:-}" in
        ubuntu:jammy|ubuntu:noble|ubuntu:resolute|debian:bookworm|debian:trixie) ;;
        *) die 'Supported: Ubuntu 22.04/24.04/26.04, Debian 12/13.' ;;
    esac
    local path
    for path in "$CONFIG" /usr/local/bin/xray /etc/systemd/system/xray.service; do
        [[ ! -e "$path" ]] || die "Existing Xray found: $path. Use --update-routing to update domains."
    done
    if systemctl cat xray.service >/dev/null 2>&1; then die 'Existing xray.service found.'; fi
    case "$(uname -m)" in
        x86_64|amd64) asset=Xray-linux-64.zip ;;
        aarch64|arm64) asset=Xray-linux-arm64-v8a.zip ;;
        *) die 'Only x86_64 and ARM64 are supported.' ;;
    esac
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl unzip jq iproute2 gnupg
    [[ -z "$(ss -H -ltn 'sport = :443')" ]] || die 'TCP 443 is occupied; existing services were not stopped.'
    if [[ -z "$server_ip" ]]; then
        server_ip=$(curl --noproxy '*' -4fsS --connect-timeout 10 --max-time 20 https://api.ipify.org || true)
    fi
    if [[ "$server_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local octet
        local -a octets
        IFS='.' read -r -a octets <<< "$server_ip"
        for octet in "${octets[@]}"; do
            (( 10#$octet <= 255 )) || die 'Invalid public IPv4.'
        done
        uri_host="$server_ip"
    elif [[ "$server_ip" == *:* && "$server_ip" =~ ^[0-9a-fA-F:]+$ ]]; then
        uri_host="[$server_ip]"
    else
        die 'Pass the public IP explicitly: bash install-reality.sh YOUR_PUBLIC_IP'
    fi
    TMP_DIR=$(mktemp -d /tmp/install-reality.XXXXXXXX)
    base_url="https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION"
    curl -fL --retry 3 --connect-timeout 20 --max-time 300 "$base_url/$asset" -o "$TMP_DIR/$asset"
    curl -fL --retry 3 --connect-timeout 20 --max-time 60 "$base_url/$asset.dgst" -o "$TMP_DIR/checksums"
    expected=$(awk -F '=' '/^SHA2-256=/ {gsub(/[[:space:]]/, "", $2); print tolower($2)}' "$TMP_DIR/checksums")
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die 'Invalid upstream SHA256 checksum.'
    actual=$(sha256sum "$TMP_DIR/$asset" | awk '{print $1}')
    [[ "$actual" == "$expected" ]] || die 'SHA256 checksum mismatch.'
    if [[ "$asset" == Xray-linux-64.zip ]]; then
        [[ "$actual" == 1eb9175d0f0a8f8149c9230a7fc5ae66ce332ed20a53155ce61fe62e3f58b7df ]] || die 'Pinned SHA256 mismatch.'
    fi
    unzip -q "$TMP_DIR/$asset" -d "$TMP_DIR/extracted"

    # Credentials are generated per installation and never stored in this repository.
    local uuid private_key public_key short_id key_output
    uuid="${UUID:-$("$TMP_DIR/extracted/xray" uuid)}"
    if [[ -n "${PRIVATE_KEY:-}" ]]; then
        key_output=$("$TMP_DIR/extracted/xray" x25519 -i "$PRIVATE_KEY")
    else
        key_output=$("$TMP_DIR/extracted/xray" x25519)
    fi
    private_key=$(x25519_field "$key_output" private)
    public_key=$(x25519_field "$key_output" public)
    short_id="${SHORT_ID:-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')}"
    [[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || die 'Invalid UUID.'
    [[ "$private_key" =~ ^[A-Za-z0-9_-]{43}$ && "$public_key" =~ ^[A-Za-z0-9_-]{43}$ ]] || die 'Could not read Xray key pair.'
    [[ "$short_id" =~ ^([0-9a-f]{2}){1,8}$ ]] || die 'SHORT_ID must contain 2 to 16 lowercase hexadecimal characters, in pairs.'

    jq -n --arg uuid "$uuid" --arg key "$private_key" --arg sid "$short_id" --arg name "$SERVER_NAME" --argjson port "$PORT" '{
      log:{loglevel:"warning",access:"/var/log/xray/access.log",error:"/var/log/xray/error.log"},
      inbounds:[{tag:"vless-reality-in",listen:"0.0.0.0",port:$port,protocol:"vless",
        settings:{clients:[{id:$uuid,flow:"xtls-rprx-vision"}],decryption:"none"},
        streamSettings:{network:"tcp",security:"reality",realitySettings:{show:false,dest:($name+":443"),xver:0,serverNames:[$name],privateKey:$key,shortIds:[$sid]}},
        sniffing:{enabled:true,destOverride:["http","tls","quic"]}}],
      outbounds:[{protocol:"freedom",tag:"direct"},{protocol:"blackhole",tag:"block"}]
    }' > "$TMP_DIR/base.json"
    add_routes "$TMP_DIR/base.json" "$TMP_DIR/config.json"
    # A fresh machine has no log directory yet; validate with temporary log paths.
    jq --arg access "$TMP_DIR/config-check.access.log" --arg error "$TMP_DIR/config-check.error.log" \
      '.log.access = $access | .log.error = $error' "$TMP_DIR/config.json" > "$TMP_DIR/config-check.json"
    "$TMP_DIR/extracted/xray" run -test -config "$TMP_DIR/config-check.json"
    setup_warp

    local backup_dir
    backup_dir="/root/reality-backup-$(date +%Y%m%d-%H%M%S)-$$"
    install -d -m 700 "$backup_dir"
    [[ ! -d /usr/local/etc/v2ray ]] || cp -a /usr/local/etc/v2ray "$backup_dir/"
    [[ ! -f /etc/systemd/system/v2ray.service ]] || cp -a /etc/systemd/system/v2ray.service "$backup_dir/"
    if ! getent passwd xray-reality >/dev/null; then
        useradd --system --user-group --no-create-home --shell /usr/sbin/nologin xray-reality
    fi
    install -d -m 755 /usr/local/share/xray /usr/local/etc/xray
    install -d -o xray-reality -g xray-reality -m 750 /var/log/xray
    touch /var/log/xray/access.log /var/log/xray/error.log
    chown xray-reality:xray-reality /var/log/xray/access.log /var/log/xray/error.log
    chmod 640 /var/log/xray/access.log /var/log/xray/error.log
    install -m 755 "$TMP_DIR/extracted/xray" /usr/local/bin/xray
    install -m 644 "$TMP_DIR/extracted/geoip.dat" /usr/local/share/xray/geoip.dat
    install -m 644 "$TMP_DIR/extracted/geosite.dat" /usr/local/share/xray/geosite.dat
    install -o root -g xray-reality -m 640 "$TMP_DIR/config.json" "$CONFIG"
    cat > /etc/systemd/system/xray.service <<'SERVICE'
[Unit]
Description=Xray VLESS Reality with selective WARP routing
After=network-online.target nss-lookup.target warp-svc.service
Wants=network-online.target warp-svc.service

[Service]
User=xray-reality
Group=xray-reality
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
SERVICE
    chmod 644 /etc/systemd/system/xray.service
    SERVICE_CREATED=1
    systemctl daemon-reload
    systemctl enable --now xray
    local attempt
    for ((attempt=0; attempt<10; attempt++)); do
        if systemctl is-active --quiet xray && ss -H -ltnp 'sport = :443' | grep -q '"xray"'; then break; fi
        sleep 1
    done
    if ! systemctl is-active --quiet xray || ! ss -H -ltnp 'sport = :443' | grep -q '"xray"'; then
        journalctl -u xray -n 30 --no-pager >&2
        die 'Xray failed to listen on TCP 443.'
    fi
    if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then ufw allow 443/tcp; fi
    local link
    link="vless://$uuid@$uri_host:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SERVER_NAME&fp=chrome&pbk=$public_key&sid=$short_id&type=tcp&headerType=none#VLESS-Reality"
    printf '%s\n' "$link" > /root/vless-reality-link.txt
    chmod 600 /root/vless-reality-link.txt
    SUCCESS=1
    printf '\nInstalled. Import link (private):\n%s\n' "$link"
    printf '\nLink: /root/vless-reality-link.txt\nBackup: %s\n' "$backup_dir"
    printf 'Allow TCP 443 in the provider firewall/security group. Existing V2Ray was left unchanged.\n'
}

main() {
    if [[ "${1:-}" == --print-domains ]]; then printf '%s\n' "${WARP_DOMAINS[@]}"; return; fi
    [[ "$EUID" == 0 ]] || die 'Run as root.'
    command -v systemctl >/dev/null || die 'systemd is required.'
    [[ -d /run/systemd/system ]] || die 'systemd must be running.'
    [[ $# -le 1 ]] || die 'Usage: bash install-reality.sh [public_IP | --update-routing | --print-domains]'
    trap cleanup EXIT
    trap 'printf "Failed at line %s.\n" "$LINENO" >&2' ERR
    case "${1:-}" in
        --update-routing) update_routes; SUCCESS=1 ;;
        --*) die 'Unknown option.' ;;
        *) install_xray "${1:-}" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
