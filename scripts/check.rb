#!/usr/bin/env ruby
# frozen_string_literal: true

# Conformance gate: recompile the .parg source, verify the corpus is
# pinned to that artifact, then replay every case — accept trees must
# match byte-for-byte (JSON), rejects must still be rejected.

require "json"

ROOT = File.expand_path("..", __dir__)
ARTIFACT = File.join(ROOT, "artifacts/express.json")
GRAMMAR = File.join(ROOT, "grammars/express.parg")
CORPUS = File.join(ROOT, "corpora/express/corpus.json")

parsanol_ruby = ENV["PARSANOL_RUBY"] || File.join(Dir.home, "src/parsanol/parsanol-ruby")
$LOAD_PATH.unshift(File.join(parsanol_ruby, "lib"))
require "parsanol"
system("ruby", "-I", File.join(parsanol_ruby, "lib"),
       File.join(parsanol_ruby, "exe/parsanol"),
       "parg", "compile", GRAMMAR, "-o", ARTIFACT) or abort "compile failed"

corpus = JSON.parse(File.read(CORPUS))
baked = JSON.parse(File.read(ARTIFACT))
if corpus["artifact_checksum"] != baked["checksum"]
  abort "corpus pinned to #{corpus['artifact_checksum'][0, 16]} but the " \
        "grammar compiles to #{baked['checksum'][0, 16]} — rebake the corpus"
end

artifact = Parsanol::PARG::Artifact.from_json(File.read(ARTIFACT))
entry = corpus["entry"]
failed = 0

corpus["cases"].each do |case_|
  name = case_["name"]
  if case_["kind"] == "reject"
    begin
      artifact.parse(entry, case_["input"])
      warn "FAIL #{name}: reject case parsed"
      failed += 1
    rescue Parsanol::ParseFailed
      # expected
    end
    next
  end
  begin
    tree = artifact.parse(entry, case_["input"])
  rescue Parsanol::ParseFailed => e
    warn "FAIL #{name}: parse error #{e.message[0, 120]}"
    failed += 1
    next
  end
  if JSON.generate(tree) != JSON.generate(case_["parsanol_tree"])
    warn "FAIL #{name}: tree diverges from the corpus"
    failed += 1
  end
end

abort "corpus: #{failed} failure(s)" if failed.positive?
puts "corpus: #{corpus['cases'].size} cases green (artifact #{baked['checksum'][0, 16]})"
