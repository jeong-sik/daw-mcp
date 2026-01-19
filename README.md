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

## MCP Tools

All tools exist as code but most are untested.

| Tool | Description | Status |
|------|-------------|--------|
| `daw_detect` | Detect running DAWs, connect | 🚧 |
| `daw_transport` | play, stop, record, pause, rewind | 🚧 |
| `daw_tempo` | Get/set BPM | 🚧 |
| `daw_select_track` | Select track by index/name | 🚧 |
| `daw_mixer` | Volume, pan, mute, solo, arm | 🚧 |
| `daw_tracks` | List all tracks | 🚧 |
| `daw_automation_read` | Read automation data | 🚧 |
| `daw_automation_write` | Write automation points | 🚧 |
| `daw_automation_mode` | Set automation mode | 🚧 |
| `daw_plugin_param` | Get/set plugin parameters | 🚧 |
| `daw_markers` | Manage markers/regions | 🚧 |
| `daw_routing` | Track routing and sends | 🚧 |
| `daw_render` | Bounce/render project | 🚧 |
| `daw_meter` | Audio level metering | 🚧 mock |
| `daw_meter_stream` | Real-time meter SSE stream | 🚧 mock |
| `daw_settings` | Audio settings (sample rate, buffer) | 🚧 |
| `daw_status` | Connection status | 🚧 |

## MCP Resources

- `daw://docs/usage` - Usage and run modes
- `daw://docs/tools` - Tool inventory

### Example Use Cases (Untested)

```
"템포 120으로"        → daw_tempo(bpm: 120)
"녹음 시작"           → daw_transport(action: "record")
"보컬 트랙 -3dB"      → daw_mixer(track: 1, volume: -3)
"기타 왼쪽으로 팬"    → daw_mixer(track: 2, pan: -50)
"여기 마커 찍어"      → daw_markers(action: "add", name: "Hook")
"이 구간 10번 반복"   → daw_markers + daw_transport (loop)
```

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
