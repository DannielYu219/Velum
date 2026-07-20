#!/bin/sh

# Prefer common local tool locations without interactive login.
# sudo -i can hang non-TTY Xcode builds when a password is required.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH${HOME:+:$HOME/.local/bin}"

ninja "$@"
