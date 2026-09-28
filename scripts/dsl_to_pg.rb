#!/usr/bin/env ruby
# frozen_string_literal: true

# Transliterates Expressir's Parsanol-DSL grammar
# (expressir/lib/expressir/express/grammar/parser.rb) into PG source.
#
# The DSL vocabulary used by that file is small and regular:
#   >> | .as(:k) .maybe .repeat .repeat(1) .absent? str("x") match["a-z"]
#   cts(x) cstr(x) keyword_rule(:KW)
# plus two generated constructs expanded here from the class's own
# constants: the tKEYWORD rules (KEYWORDS.each) and anyKeyword.
#
# Ruby's >> and | have equal left-associative precedence, so bodies are
# folded left-to-right over both operators at once; composites are
# parenthesized liberally in the emitted PG (parens are primaries).

require "json"
require "strscan"

SRC = ARGV[0] or abort "usage: dsl_to_pg.rb <parser.rb> <out.pg>"
OUT = ARGV[1] or abort "usage: dsl_to_pg.rb <parser.rb> <out.pg>"
src = File.read(SRC)

# ---- extract KEYWORDS and expand the two loop-generated constructs ----
keywords = src[/KEYWORDS = %i\[(.*?)\]\.freeze/m, 1].split.map(&:to_sym)
abort "KEYWORDS not found" if keywords.empty?

# ---- extract rule bodies in source order ----
rules = [] # [name, body_string]
pos = 0
while (m = src.match(/rule\(:([A-Za-z_][A-Za-z0-9_]*)\)\s*(\{|do)/, pos))
  name = m[1]
  body_start = m.end(0)
  if m[2] == "{"
    depth = 1
    i = body_start
    in_str = nil
    while depth.positive?
      ch = src[i]
      if ch.nil?
        abort "unterminated braced rule near #{src[body_start, 60].inspect}"
      elsif in_str
        if ch == "\\"
          i += 2
          next
        end
        in_str = nil if ch == in_str
      elsif ch == '"' || ch == "'"
        in_str = ch
      elsif ch == "{"
        depth += 1
      elsif ch == "}"
        depth -= 1
      end
      i += 1
    end
    body = src[body_start...i - 1]
    pos = i
  else
    depth = 1
    mm = nil
    j = body_start
    while depth.positive? && (mm = src.match(/\b(do|end)\b/, j))
      mm[0] == "do" ? depth += 1 : depth -= 1
      j = mm.end(0)
    end
    body = src[body_start...mm.begin(0)]
    pos = mm.end(0)
  end
  rules << [name, body]
end
abort "no rules found" if rules.empty?



def clean(body)
  body.gsub(/#.*$/, " ").gsub(/\s+/, " ").strip
end

BOUNDARY = "(%x41-5A / %x61-7A / %x30-39 / %x5F)".freeze

# ---- expression translation ----
def translate_expr(text)
  # fold >> and | left-associatively (Ruby precedence: equal, left)
  parts = split_top(text, [">>", "|"])
  abort "empty expression in: #{text[0, 80]}" if parts.empty?
  rendered = parts.map { |t| translate_term(t[:term]) }
  return rendered[0] if rendered.size == 1

  # interleave with the operators; PG has / looser than juxtaposition,
  # so a top-level alternation is parenthesized by the caller when
  # needed. Ruby folding means the operator sequence must be preserved:
  out = rendered[0]
  (parts.size - 1).times do |i|
    # the operator joining parts[i] to parts[i+1] lives on parts[i]
    out = if parts[i][:op] == "|"
      "(#{out} / #{rendered[i + 1]})"
    else
      "(#{out} #{rendered[i + 1]})"
    end
  end
  out
end

def scan_depth(text)
  # yields [char, depth, in_string]; skips quoted spans
  depth = 0
  in_str = nil
  i = 0
  while i < text.length
    ch = text[i]
    if in_str
      if ch == "\\"
        i += 2
        next
      end
      in_str = nil if ch == in_str
    elsif ch == '"' || ch == "'"
      in_str = ch
    elsif ch == "(" || ch == "["
      depth += 1
    elsif ch == ")" || ch == "]"
      depth -= 1
    end
    yield ch, depth, in_str, i
    i += 1
  end
end

def split_top(text, ops)
  parts = []
  buf = +""
  depth = 0
  in_str = nil
  i = 0
  while i < text.length
    ch = text[i]
    if in_str
      buf << ch
      if ch == "\\"
        buf << text[i + 1] if i + 1 < text.length
        i += 2
        next
      end
      in_str = nil if ch == in_str
      i += 1
      next
    end
    if ch == '"' || ch == "'"
      in_str = ch
      buf << ch
      i += 1
      next
    end
    depth += 1 if ch == "(" || ch == "["
    depth -= 1 if ch == ")" || ch == "]"
    if depth.zero?
      two = text[i, 2]
      if ops.include?(two)
        parts << { term: buf.strip, op: two }
        buf = +""
        i += 2
        next
      end
      if ch == "|"
        parts << { term: buf.strip, op: "|" }
        buf = +""
        i += 1
        next
      end
    end
    buf << ch
    i += 1
  end
  parts << { term: buf.strip, op: nil }
  parts.reject { |p| p[:term].empty? }
end

PRIMARY_RE = /\A(str\(|match\[|match\()/x.freeze

def composite?(pg)
  # a rendered PG fragment that needs parens when a suffix binds it
  return false if pg.start_with?("(") && pg.end_with?(")") && balanced_solo?(pg)
  return false if pg.start_with?("[") && pg.end_with?("]")
  return false if pg =~ PRIMARY_RE || pg.start_with?('"') || pg.start_with?('%')
  true
end

def balanced_solo?(pg)
  depth = 0
  pg.each_char do |ch|
    depth += 1 if ch == "("
    depth -= 1 if ch == ")"
    return false if depth.zero? && pg.index(ch) < pg.length - 1 && ch != "(" && ch != ")"
  end
  depth.zero?
end

def paren_if(pg)
  composite?(pg) ? "(#{pg})" : pg
end

def translate_term(text)
  # peel suffixes: .as(:k) / .maybe / .repeat / .repeat(1) / .absent?
  suffixes = []
  loop do
    case text
    when /\.as\(:([A-Za-z_][A-Za-z0-9_]*)\)\z/
      suffixes << [:as, Regexp.last_match(1)]
      text = text[0...Regexp.last_match.begin(0)].strip
    when /\.maybe\z/
      suffixes << [:maybe]
      text = text[0...Regexp.last_match.begin(0)].strip
    when /\.repeat\(1\)\z/
      suffixes << [:rep1]
      text = text[0...Regexp.last_match.begin(0)].strip
    when /\.repeat\z/
      suffixes << [:rep]
      text = text[0...Regexp.last_match.begin(0)].strip
    when /\.absent\?\z/
      suffixes << [:absent]
      text = text[0...Regexp.last_match.begin(0)].strip
    else
      break
    end
  end

  pg = translate_call(text)
  suffixes.reverse_each do |sfx|
    case sfx[0]
    when :as then pg = "(#{pg}) as #{sfx[1]}"
    when :maybe then pg = composite?(pg) ? "[#{pg}]" : "[ #{pg} ]"
    when :rep then pg = "*#{paren_if(pg)}"
    when :rep1 then pg = "1*#{paren_if(pg)}"
    when :absent then pg = "!#{paren_if(pg)}"
    end
  end
  pg
end

def wrapped_in_parens?(text)
  close = nil
  scan_depth(text) do |ch, depth, _in_str, i|
    close = i if depth.zero? && (ch == ")" || ch == "]")
  end
  close == text.length - 1 && text.start_with?("(")
end

def translate_call(text)
  if text.start_with?("(")
    raise "nested composite term: #{text.inspect}" unless wrapped_in_parens?(text)
    return translate_expr(text[1..-2])
  end
  case text
  when /\Astr\((.*)\)\z/m
    literal(Regexp.last_match(1))
  when /\Amatch\[(.*)\]\z/m, /\Amatch\((.*)\)\z/m
    char_class(eval(Regexp.last_match(1))) # rubocop:disable Security/Eval
  when /\Acts\((.*)\)\z/m
    "spaces #{paren_if(translate_expr(Regexp.last_match(1)))}"
  when /\Acstr\((.*)\)\z/m
    "spaces (#{literal(Regexp.last_match(1))} as str)"
  when /\Akeyword_rule\((:)?("([^"]+)")\)\z/, /\Akeyword_rule\(("([^"]+)")\)\z/
    kw = Regexp.last_match(2) || Regexp.last_match(3)
    "((%i\"#{kw.downcase}\" !(#{BOUNDARY})) as str)"
  when /\A[A-Za-z_][A-Za-z0-9_]*\z/
    text == "any" ? "any_char" : text
  else
    raise "untranslatable term: #{text[0, 120]}"
  end
end

def literal(ruby_str_literal)
  value = eval(ruby_str_literal) # rubocop:disable Security/Eval
  escaped = value.gsub("\\") { "\\\\" }
                 .gsub('"') { '\\"' }
                 .gsub("\n") { "\\n" }
                 .gsub("\t") { "\\t" }
                 .gsub("\r") { "\\r" }
  %("#{escaped}")
end

def char_class(spec)
  parts = []
  i = 0
  s = spec
  while i < s.length
    if i + 2 < s.length && s[i + 1] == "-" && s[i + 2] != "-"
      lo, hi = s[i], s[i + 2]
      parts << (lo.ord == hi.ord - 1 ? "%x#{sprintf('%02X', lo.ord)} / \"#{hi}\"" : "%x#{sprintf('%02X', lo.ord)}-#{sprintf('%02X', hi.ord)}")
      i += 3
    elsif s[i] == "\\" && i + 1 < s.length
      parts << %("#{s[i + 1]}")
      i += 2
    else
      parts << %("#{esc(s[i])}")
      i += 1
    end
  end
  "(#{parts.join(' / ')})"
end

def esc(ch)
  case ch
  when "\n" then "\\n"
  when "\t" then "\\t"
  when "\r" then "\\r"
  when "\\" then "\\\\"
  when '"' then '\\"'
  else ch
  end
end

# ---- emit ----
out = +""
out << <<~HEADER
  # EXPRESS (ISO 10303-11) concrete syntax, ported from Expressir's
  # Parsanol-DSL grammar (lib/expressir/express/grammar/parser.rb).
  # The DSL rules transliterate one-to-one; the tKEYWORD rules and
  # anyKeyword are the KEYWORDS.each / inject(:|) loops expanded.
  # Root: syntax (the DSL's root(:syntax)).

  grammar Express version "0.1.0" {

    # character classes shared by the keyword boundary predicate
    ident_char = %x41-5A / %x61-7A / %x30-39 / %x5F
    any_char = %x00-10FFFF

HEADER

rules.each do |name, body|
  text = clean(body)
  if name == "anyKeyword"
    alts = keywords.map { |kw| "t#{kw}" }.join(" / ")
    out << "  anyKeyword = (#{alts})\n"
    next
  end
  begin
    out << "  #{name} = #{translate_expr(text)}\n"
  rescue StandardError => e
    abort "rule #{name}: #{e.message}"
  end
end

# the tKEYWORD rules, at the position after the last helper-derived rule
keywords.each do |kw|
  out << "  t#{kw} = ((spaces ((%i\"#{kw.to_s.downcase}\" !(#{BOUNDARY})) as str)) as t#{kw})\n"
end

out << "  entry syntax: syntax\n"
out << "}\n"
File.write(OUT, out)
puts "wrote #{OUT}: #{rules.size} rules + #{keywords.size} keyword rules"
