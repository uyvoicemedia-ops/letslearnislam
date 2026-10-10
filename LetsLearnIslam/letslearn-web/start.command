#!/bin/bash
# Double-click this to put LetsLearn on the wifi.
# It prints two addresses: one for this Mac, one for everyone else.
cd "$(dirname "$0")"
exec python3 -u tools/llserve.py 8765
