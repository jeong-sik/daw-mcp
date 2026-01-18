# DAW MCP

> 🧪 **Personal experiment.** Not production-ready.

MCP server for controlling DAWs (Digital Audio Workstations) via AI.

## Supported DAWs

- Logic Pro
- Cubase
- Pro Tools
- Ableton Live
- FL Studio
- Reaper
- MainStage

## Features

- Natural language sound design ("make it warmer", "add punch")
- MIDI CC control via YAML profiles
- OSC and AppleScript integration

## Requirements

- OCaml 5.2+
- macOS (for DAW integration)

## Quick Start

```bash
# Build
dune build

# Run (HTTP mode)
./start-daw-mcp.sh --http --port 8950

# Run (stdio mode for MCP)
./start-daw-mcp.sh
```

## License

MIT
