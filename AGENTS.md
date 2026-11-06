# Deployment Notes

This repository exists to reproduce the user's VLESS Reality setup on replacement servers.

- Read README.md before deploying. Deployment requires a user-provided server and SSH authorization.
- Use official Xray releases and Cloudflare APT packages. Keep WARP in local proxy mode on 127.0.0.1:40000; do not change the server default route to WARP.
- Keep direct as the first/default Xray outbound. Only WARP_DOMAINS go through WARP.
- For domain-only changes, edit WARP_DOMAINS, run routing tests, then use --update-routing on the authorized server. Preserve all existing credentials and unrelated routing rules.
- For a fresh server, the installer generates new credentials. Reusing credentials requires private environment variables; never commit them, live config files, import links, or account registration state.
- Tests: bash -n install-reality.sh && bash tests/routing.sh && bash tests/credentials.sh (requires jq). After an authorized deployment, run bash tests/live-probe.sh SERVER_IP on that server.
- Validate actual routing through the VLESS inbound and access logs. HTTP 403 is not proof of a routing failure, nor is a routing match proof that account login works.
- Back up before any production config update; validate with xray run -test before restart. Do not restart an existing service just to test a fresh installation script.
