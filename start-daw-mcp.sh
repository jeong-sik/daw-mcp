#!/bin/bash
# DAW MCP Server startup script

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Check if built
if [ ! -f "_build/default/bin/main.exe" ]; then
    echo "Building daw-mcp..."
    dune build
fi

# Parse arguments
MODE="stdio"
PORT=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --http)
            MODE="http"
            shift
            ;;
        --port|-p)
            PORT="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE="-v"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Run
if [ "$MODE" = "http" ]; then
    PORT="${PORT:-8950}"
    echo "Starting DAW MCP in HTTP mode on port $PORT..."
    exec dune exec daw-mcp -- --port "$PORT" $VERBOSE
else
    echo "Starting DAW MCP in stdio mode..."
    exec dune exec daw-mcp -- $VERBOSE
fi
