#!/bin/bash

set -e

launchctl remove com.xconnect.xray-node-jp || true
launchctl remove com.xconnect.xray-node-ca || true
launchctl remove com.xconnect.xray-node-us || true

rm -f /opt/homebrew/bin/xray
rm -rf /opt/homebrew/etc/xray-vpn-node*

rm -rf ~/Library/LaunchAgents/com.xconnect.*
rm -rf ~/Library/LaunchAgents/xconnect*
rm -rf ~/Library/Application\ Support/plus.svc.xconnect/*
# Keep cleaning the legacy location so upgrades do not leave stale runtime files.
rm -rf ~/Library/Application\ Support/plus.svc.xconnect/*
