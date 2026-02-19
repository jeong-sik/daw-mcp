(lang dune 3.16)

(name daw_mcp)

(version 0.2.1)

(generate_opam_files true)

(source
 (github jeong-sik/me))

(authors "Seungji Hong <yousleepwhen@gmail.com>")

(maintainers "Seungji Hong <yousleepwhen@gmail.com>")

(license MIT)

(documentation https://github.com/jeong-sik/me/features/daw-mcp)

(package
 (name daw_mcp)
 (synopsis "DAW MCP Server - Control all DAWs via AI")
 (description
  "Pure OCaml 5.x MCP server for controlling DAWs (Logic Pro, Cubase, Pro Tools, Ableton, FL Studio, Reaper, MainStage) via OSC, AppleScript, and Plugin Bridge")
 (depends
  (ocaml (>= 5.2))
  (dune (>= 3.16))
  (eio (>= 1.0))
  (eio_main (>= 1.0))
  (cohttp-eio (>= 6.0))
  (yojson (>= 2.0))
  (ppx_deriving_yojson (>= 3.7))
  (cstruct (>= 6.0))
  (angstrom (>= 0.16))
  (faraday (>= 0.8))
  (logs (>= 0.7))
  (fmt (>= 0.9))
  (cmdliner (>= 1.2))
  (dune-build-info (>= 0.1))
  (ppx_deriving (>= 5.2))
  (alcotest (>= 1.7))
  (bisect_ppx (and :with-test (>= 2.8))))
 (tags
  (daw mcp osc audio "music production")))
