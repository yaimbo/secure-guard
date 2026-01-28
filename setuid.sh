#!/bin/bash
while true; do
    chown root:wheel target/release/secureguard-poc 2>/dev/null
    chmod u+s target/release/secureguard-poc 2>/dev/null
    sleep 1
done
