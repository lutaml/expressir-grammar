# expressir-grammar roadmap

## Phase 0 — DONE (2026-09-28)

- `grammars/express.pg` ported from Expressir's Parsanol-DSL grammar
  (249 rules + 123 expanded keyword rules) via
  `scripts/dsl_to_pg.rb`.
- `artifacts/express.json` compiles green (deterministic checksum
  `sha256:1e49bc96…`).
- Tree parity vs the DSL grammar: 15/15 parseable `spec/syntax`
  fixtures JSON-identical.
- `corpora/express/corpus.json` baked (15 accept / 4 reject), pinned
  to the artifact checksum; `scripts/check.rb` replays it green.

## Phase 1 — triage the 7503 compile warnings

The compiler's order-dependent-alternative and shadowing lints fire
en masse on the keyword alternations (123 `tKEYWORD` rules folded into
`anyKeyword`) and the expression-grammar alternatives. Triage: confirm
the order is intentional (ISO 10303-11 is a direct transcription), then
either annotate or restructure. Target: warnings down to a reviewed
baseline.

## Phase 2 — wire the Ruby consumer (expressir)

`Expressir::Express::Grammar::Parser` gains an artifact-backed parse
path (the R2 seam pattern from the pubid swaps): the artifact is
vendored/loaded from this repo (or a released package), `parse` routes
the SAME string through the artifact, and the Builder consumes the
parsanol-shape tree unchanged. Gate: expressir's full spec suite
(1558 specs) green with the artifact backend, plus the eeng corpus.

## Phase 3 — wire the Rust consumer (expressir-rs)

Replace the embedded `assets/express-grammar.json` (the serialized DSL
grammar, `include_str!`d in `src/lib.rs`) with this repo's baked
artifact: same portable Grammar, checksum-verified load, corpus gate in
`tests/` (the pg_corpus.rs pattern: `PG_ARTIFACT_DIR`/corpus env, skip
when absent). Note: expressir-rs currently pins `parsanol = "=0.8.9"`;
0.9.0 carries the PG runtime.

## Phase 4 — cross-runtime gate + release

- A CI workflow like pubid-grammar's `pg-conformance.yml` (grammar
  compile + rust + ts legs).
- Decide the distribution: this repo as the source of truth with
  consumers pinning a tag, and/or artifacts published alongside the
  expressir gem releases.
- TS/wasm leg (pubid-ts pattern) if expressir gains a TS consumer.
