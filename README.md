# DAW MCP

> 🧪 **Personal experiment.** Not production-ready.

MCP server for controlling DAWs (Digital Audio Workstations) via AI.

## Goal

AI-assisted sound design feedback loop:

```
You: "Play a chord"
  ↓
MIDI → DAW → Sound plays ✅ (working)
  ↓
Audio capture → AI analysis ❌ (TODO)
  ↓
AI: "Try boosting the low end"
```

The dream: real-time sound design feedback without leaving the terminal.

## Architecture

```
┌─────────────────┐     MIDI     ┌─────────┐
│  OCaml MCP      │─────────────▶│  DAW    │  ✅ Working
│  Server         │              │         │
└─────────────────┘              └─────────┘

         (future)
              │
              ▼
┌──────────────────┐     Audio    ┌─────────┐
│  DAW Bridge AU   │◀────────────│  DAW    │  ❌ Not yet
│  (Audio Unit)    │             │         │
└──────────────────┘             └─────────┘
        │
        ▼
  Audio Analysis → AI Feedback
```

- **OCaml MCP Server**: Handles MCP protocol, controls DAW
- **DAW Bridge AU**: Audio Unit plugin (⚠️ untested, code only)
- **xcode/**: AU plugin source (ObjC)

## Status

> ⚠️ Only tested with MainStage + MIDI input. Everything else is code-only.

| DAW | Status | Protocol |
|-----|--------|----------|
| MainStage | 🧪 Tested (MIDI only) | MIDI |
| Reaper | ❓ Untested | OSC |
| Logic Pro | ❓ Untested | AppleScript |
| Ableton Live | ❓ Untested | OSC |
| Cubase | ❌ TODO | - |
| Pro Tools | ❌ TODO | - |
| FL Studio | ❌ TODO | - |

## Features

| Feature | Status |
|---------|--------|
| MIDI input to DAW | ✅ Tested |
| Transport, Mixer, Automation, etc. | 🚧 Code exists, untested |
| Real-time audio metering | 🚧 Mock data only |
| Natural language sound design | ❌ TODO |
| Audio stream analysis | ❌ TODO |

## Requirements

- OCaml 5.2+
- macOS 12+ (for AU plugin)
- Xcode 15+ (to build AU plugin)

## Quick Start

```bash
# Build MCP server
dune build

# Build AU plugin (optional)
cd xcode && xcodebuild

# Run (HTTP mode)
./start-daw-mcp.sh --http --port 8950

# Run (stdio mode for MCP)
./start-daw-mcp.sh
```

## TODO

- [ ] Audio stream analysis via AU plugin
- [ ] Natural language sound design ("make it warmer")
- [ ] Real metering (not mock data)
- [ ] Test with other DAWs
- [ ] Documentation

## License

MIT
