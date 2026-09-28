# expressir-grammar

The language-independent **contract** for EXPRESS (ISO 10303-11) parsing:
the parsanol grammar source, its baked artifact, and the conformance
corpus every engine must replay.

Mirrors the pubid-grammar contract: **the baked artifact is the only
parsing input** — consumers (expressir ruby, expressir-rs, future TS)
never re-transcribe the grammar.

## Layout

- `grammars/express.parg` — the grammar source (SSOT). Ported 1:1 from
  Expressir's Parsanol-DSL grammar; the `tKEYWORD` rules and
  `anyKeyword` are the DSL's `KEYWORDS.each` / `inject(:|)` loops
  expanded.
- `artifacts/express.json` — the checksummed artifact envelope. Verify
  loudly on load; never fall back on a checksum mismatch.
- `corpora/express/corpus.json` — frozen conformance cases (inputs +
  parsanol-shape trees, accept and reject), pinned to the artifact
  checksum by `artifact_checksum`.
- `scripts/dsl_to_parg.rb` — the transliterator that produced the .parg
  from Expressir's DSL grammar (kept for provenance and re-runs).
- `scripts/bake_corpus.rb` — regenerates the corpus from the current
  artifact.
- `scripts/check.rb` — the conformance gate: recompile, verify the
  corpus pin, replay every case.

## Conformance

```
ruby scripts/check.rb
```

Baseline (2026-09-28): the artifact's trees are JSON-identical to
Expressir's DSL grammar on all parseable `spec/syntax` fixtures
(15/15; the two fixtures the DSL itself rejects —
`multiple_schema_head_hyperlink_formatted.exp`,
`syntax_schema_head_formatted.exp` — are facade-preprocessed forms and
are excluded from the corpus rather than frozen as rejects).

## Next phases

See `TODO.expressir-grammar/00-roadmap.md`.
