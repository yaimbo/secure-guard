#!/bin/bash
while true; do
    chown root:wheel target/release/minnowvpn 2>/dev/null
    chmod u+s target/release/minnowvpn 2>/dev/null
    # Make auth token readable for testing (normally 0640 root:minnowvpn)
    chmod 644 /var/run/minnowvpn/auth-token 2>/dev/null
    sleep 1
done
