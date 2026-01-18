# CLAP Plugin Build
# Builds the minimal C shim + OCaml runtime

OCAML_PREFIX := $(shell ocamlfind printconf destdir)/..
OCAML_INCLUDE := $(OCAML_PREFIX)/lib/ocaml
OCAML_LIB := $(OCAML_PREFIX)/lib/ocaml

# Plugin name
PLUGIN_NAME := daw-bridge
PLUGIN_FILE := $(PLUGIN_NAME).clap

# Compiler flags
CC := clang
CFLAGS := -Wall -Wextra -O2 -fPIC -fvisibility=hidden
CFLAGS += -I$(OCAML_INCLUDE)

# macOS specific
UNAME := $(shell uname)
ifeq ($(UNAME), Darwin)
    LDFLAGS := -bundle -undefined dynamic_lookup
    LDFLAGS += -L$(OCAML_LIB) -lasmrun_pic -lunixnat
else
    LDFLAGS := -shared
    LDFLAGS += -L$(OCAML_LIB) -lasmrun_pic -lunixnat -lm -ldl
endif

# Source files
CSRC := clap_entry.c
BUILD_DIR := ../../../_build/default/daw-mcp/plugin/ocaml
OCAML_LIB_A := $(BUILD_DIR)/daw_bridge.a

# AU Plugin (macOS only) - must define before targets
AU_NAME := DAWBridge.component
AU_SRC := au_entry.mm au_view_controller.mm

# Targets
.PHONY: all clean install build-ocaml clap au install-au

all: clap

clap: $(PLUGIN_FILE)

au: $(AU_NAME)

build-ocaml:
	cd ../.. && dune build plugin/ocaml/daw_bridge.a

$(PLUGIN_FILE): build-ocaml $(CSRC)
	$(CC) $(CFLAGS) $(CSRC) $(OCAML_LIB_A) $(LDFLAGS) -o $@

# AU Plugin build rule (macOS only) - IPC mode (no embedded OCaml)

ifeq ($(UNAME), Darwin)
# AU plugin uses IPC to communicate with MCP server
# No OCaml runtime needed - pure Objective-C++ with std::shared_ptr
$(AU_NAME): $(AU_SRC)
	mkdir -p $(AU_NAME)/Contents/MacOS
	clang++ -std=c++17 -fobjc-arc \
		-framework AudioToolbox -framework AVFoundation -framework Foundation \
		-framework CoreAudioKit -framework Cocoa -framework CoreMIDI \
		-Wall -Wextra -O2 \
		$(AU_SRC) \
		-lc++ \
		-bundle -o $(AU_NAME)/Contents/MacOS/DAWBridge
	cp Info.plist.template $(AU_NAME)/Contents/Info.plist
endif

clean:
	rm -f $(PLUGIN_FILE) *.o
	rm -rf $(AU_NAME)

install: $(PLUGIN_FILE)
ifeq ($(UNAME), Darwin)
	mkdir -p ~/Library/Audio/Plug-Ins/CLAP
	cp $(PLUGIN_FILE) ~/Library/Audio/Plug-Ins/CLAP/
else
	mkdir -p ~/.clap
	cp $(PLUGIN_FILE) ~/.clap/
endif

install-au: $(AU_NAME)
ifeq ($(UNAME), Darwin)
	mkdir -p ~/Library/Audio/Plug-Ins/Components
	cp -r $(AU_NAME) ~/Library/Audio/Plug-Ins/Components/
endif

# Debug build
debug: CFLAGS += -g -DDEBUG
debug: $(PLUGIN_FILE)

# Show OCaml paths (for debugging)
info:
	@echo "OCAML_PREFIX: $(OCAML_PREFIX)"
	@echo "OCAML_INCLUDE: $(OCAML_INCLUDE)"
	@echo "OCAML_LIB: $(OCAML_LIB)"
