#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT_DIR/install-reality.sh"
private_key=$(printf '%043d' 0)
public_key=$(printf '%043d' 1)
for public_label in 'Password (PublicKey)' Password PublicKey 'Public key'; do
    for private_label in PrivateKey 'Private key'; do
        output=$(printf '%s: %s\r\n%s: %s\r\nHash32: ignored\r\n' "$private_label" "$private_key" "$public_label" "$public_key")
        [[ "$(x25519_field "$output" private)" == "$private_key" ]]
        [[ "$(x25519_field "$output" public)" == "$public_key" ]]
    done
done
[[ -z "$(x25519_field 'Unknown: ignored' public)" ]]
printf 'Credential parsing tests passed.\n'
