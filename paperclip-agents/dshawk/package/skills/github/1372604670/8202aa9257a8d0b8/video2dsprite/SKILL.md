---
name: "video2dsprite"
description: "Turn one approved master still into a character's whole animated sprite set - one image-to-video clip per action (idle, walk, run, attack, jump, hurt, cast and so on), all from that still, generated through generate2dmedia route_media.py (the xAI API when a key is configured, else the local Grok CLI) - then gate each take, key it with a soft matte, register it to the master, pick loops or retime actions, finish (HD by default, pixel on request) and package fixed-canvas frames, alpha WebM, packed MP4 for iPhone and a PNG fallback with engine metadata and a JS runtime. Also processes a supplied clip. Use for character and creature animation, fluid motion and any video-to-sprite work. Not for FX, icon or prop sheets (generate2dsprite), maps or plate loops (generate2dmap), code-drawn animation (codeart2d, only on request) or calling a video API by itself (generate2dmedia)."
slug: "video2dsprite"
metadata:
  sources:
    -
      kind: "github-dir"
      commit: "a6110b3c6f5261b572f2a37530fc9dc86bce6ff5"
      path: "agent-sprite-forge/skills/video2dsprite"
      repo: "dshawk/skils"
      trackingRef: "main"
      url: "https://github.com/dshawk/skils"
key: "github/1372604670/8202aa9257a8d0b8/video2dsprite"
---

