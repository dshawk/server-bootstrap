#!/bin/bash
# Route ONLY gemini through Cloudflare WARP local proxy (mode=proxy, not full tunnel).
export HTTPS_PROXY="${HTTPS_PROXY:-http://127.0.0.1:40000}"
export HTTP_PROXY="${HTTP_PROXY:-http://127.0.0.1:40000}"
export https_proxy="${https_proxy:-$HTTPS_PROXY}"
export http_proxy="${http_proxy:-$HTTP_PROXY}"
export ALL_PROXY="${ALL_PROXY:-socks5h://127.0.0.1:40000}"
export all_proxy="${all_proxy:-$ALL_PROXY}"
export NO_PROXY="${NO_PROXY:-127.0.0.1,localhost,::1}"
export no_proxy="${no_proxy:-$NO_PROXY}"
exec /usr/bin/gemini "$@"
