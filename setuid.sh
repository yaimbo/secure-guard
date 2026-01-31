#!/bin/bash
while true; do
    chown root:wheel target/release/secureguard-poc 2>/dev/null
    chmod u+s target/release/secureguard-poc 2>/dev/null
    # Make auth token readable for testing (normally 0640 root:secureguard)
    chmod 644 /var/run/secureguard/auth-token 2>/dev/null
    sleep 1
done
