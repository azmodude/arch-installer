#!/bin/bash

set -Eeuxo pipefail

# get and lsign archzfs keys
pacman-key --keyserver keyserver.ubuntu.com -r DDF7DB817396A49B2A2723F7403BD972F75D9D76
pacman-key --lsign-key DDF7DB817396A49B2A2723F7403BD972F75D9D76

pacman -Sy archzfs-linux archzfs-linux-lts archzfs-linux-zen

