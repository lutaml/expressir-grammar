#!/usr/bin/env ruby
# frozen_string_literal: true

# Bakes corpora/express/corpus.json: every case freezes the input and
# the parsanol-shape tree the baked artifact must reproduce. Inputs
# come from expressir's spec/syntax fixtures (the parity gate the DSL
# grammar passes) plus hand-picked rejects.

require "parsanol"
require "json"
require "fileutils"

ROOT = __dir__
ARTIFACT = File.expand_path("../artifacts/express.json", __dir__)
CORPUS = File.expand_path("../corpora/express/corpus.json", __dir__)
SYNTAX = "/Users/mulgogi/src/lutaml/expressir/spec/syntax"

REJECTS = [
  "SCHEMA",                     # truncated header
  "SCHEMA a END_SCHEMA;",       # missing delimiter
  "ENTITY e; END_SCHEMA;",      # mismatched block
  "SCHEMA a; TYPE t; END_TYPE; END_SCHEMA;", # unterminated type body
].freeze

artifact = Parsanol::PARG::Artifact.load(ARTIFACT)
entry = artifact.entries.first

cases = []
Dir["#{SYNTAX}/*.exp"].sort.each do |f|
  src = File.read(f)
  tree = artifact.parse(entry, src)
  cases << { "input" => src, "kind" => "accept", "name" => File.basename(f, ".exp"),
             "parsanol_tree" => tree }
rescue Parsanol::ParseFailed
  # the DSL grammar rejects these too (facade-preprocessed forms);
  # freezing them as rejects would pin engine quirks, so skip
  warn "skipping unparseable-by-grammar fixture: #{File.basename(f)}"
end

REJECTS.each do |src|
  begin
    raise "reject case unexpectedly parses: #{src.inspect}" if artifact.parse(entry, src)
  rescue Parsanol::ParseFailed
    # expected: the grammar must refuse these
  end
  cases << { "input" => src, "kind" => "reject", "name" => "reject-#{cases.size}" }
end

FileUtils.mkdir_p(File.dirname(CORPUS))
File.write(CORPUS, JSON.pretty_generate(
  "artifact_checksum" => JSON.parse(File.read(ARTIFACT))["checksum"],
  "entry" => entry,
  "cases" => cases
))
puts "baked #{CORPUS}: #{cases.size} cases " \
     "(#{cases.count { |c| c['kind'] == 'accept' }} accept / " \
     "#{cases.count { |c| c['kind'] == 'reject' }} reject)"
