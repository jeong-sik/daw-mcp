# DAW MCP

> 🧪 **Personal experiment.** Not production-ready.

MCP server for controlling DAWs (Digital Audio Workstations) via AI.

## Goal

AI-assisted sound design: trigger MIDI → loop audio → analyze stream → get feedback like "boost the low end" or "reduce the reverb".

## Status

> ⚠️ Only tested with MainStage. Other DAWs are implemented but untested.

| DAW | Status | Protocol |
|-----|--------|----------|
| MainStage | 🧪 Tested | MIDI |
| Reaper | ❓ Untested | OSC |
| Logic Pro | ❓ Untested | AppleScript |
| Ableton Live | ❓ Untested | OSC |
| Cubase | ❌ TODO | - |
| Pro Tools | ❌ TODO | - |
| FL Studio | ❌ TODO | - |

## Features

| Feature | Status |
|---------|--------|
| Transport (play/stop/record) | ✅ |
| Tempo control | ✅ |
| Track selection | ✅ |
| Mixer (volume/pan/mute/solo) | ✅ |
| Automation read/write | ✅ |
| Plugin parameters | ✅ |
| Markers/regions | ✅ |
| Routing/sends | ✅ |
| Render/bounce | ✅ |
| Real-time metering | ✅ |
| Natural language sound design | ❌ TODO |
| MIDI CC profiles | ❌ TODO |

## Requirements

- OCaml 5.2+
- macOS (for DAW integration)
- DAW with OSC support enabled

## Quick Start

```bash
# Build
dune build

# Run (HTTP mode)
./start-daw-mcp.sh --http --port 8950

# Run (stdio mode for MCP)
./start-daw-mcp.sh
```

## TODO

- [ ] Natural language sound design ("make it warmer")
- [ ] YAML-based MIDI CC profiles
- [ ] Cubase/Pro Tools/FL Studio support
- [ ] Windows/Linux support
- [ ] Documentation

## License

MIT
