#!/usr/bin/env ruby
# frozen_string_literal: true

# Derives one YAML sibling per bibxml reference under data/, because
# `relaton index` (the GitHub Pages build) only reads *.{yaml,yml}.
# The raw XML stays the canonical artifact — the YAML is derived and
# regenerated whenever the source changes.
#
# Idempotent by content, not mtime: an existing sibling is compared
# against freshly generated output and rewritten only on difference, so
# a daily crawler that re-downloads an unchanged corpus produces zero
# churn. Deterministic output is what makes that safe.
#
# <referencegroup> roots (BCP/STD/FYI) become one group record with an
# `includes` relation per constituent, mirroring the shape the official
# relaton-data-rfcsubseries fetcher emits for the same series.

require "nokogiri"
require "relaton"

DATA_DIR = File.expand_path("data", __dir__)

GROUP_TITLES = {
  "BCP" => "Best Current Practice",
  "STD" => "Internet Standard technical specification",
  "FYI" => "For Your Information",
}.freeze

def group_hash(doc)
  anchor = doc.root["anchor"].to_s
  m = anchor.match(/\A([A-Z]+)(\d+)\z/)
  return unless m && GROUP_TITLES.key?(m[1])

  # The bibxml corpus is namespace-free; select by element name.
  constituents = doc.root.element_children.select { |c| c.name == "reference" }.map do |ref|
    begin
      Relaton::Ietf::BibXMLParser.parse(ref.to_xml).to_hash
    rescue StandardError
      # A constituent that cannot be parsed still counts: its anchor
      # (RFC1915 -> "RFC 1915") names it via formattedref.
      { "formattedref" => { "content" => ref["anchor"].sub(/\A([A-Z]+)(\d+)\z/, '\1 \2') } }
    end
  end

  {
    "id" => anchor,
    "type" => "standard",
    "formattedref" => { "content" => anchor },
    "title" => [{
      "language" => "en", "script" => "Latn",
      "content" => "#{GROUP_TITLES.fetch(m[1])} #{m[2]}",
    }],
    "source" => [{ "type" => "src", "content" => doc.root["target"] }],
    "docidentifier" => [{ "content" => "#{m[1]} #{m[2]}", "type" => "IETF", "primary" => true }],
    "docnumber" => anchor,
    "language" => ["en"],
    "script" => ["Latn"],
    "relation" => constituents.map { |c| { "type" => "includes", "bibitem" => c } },
  }
end

def yaml_for(xml)
  content = File.read(xml, encoding: "utf-8").scrub
  doc = Nokogiri::XML(content) { |c| c.norecover.strict }
  item =
    if doc.root&.name == "referencegroup"
      hash = group_hash(doc)
      return nil unless hash

      Relaton::Ietf::Item.from_hash(hash)
    else
      Relaton::Ietf::BibXMLParser.parse(content)
    end
  item.to_yaml
end

converted = up_to_date = failed = 0

Dir[File.join(DATA_DIR, "*.xml")].sort.each do |xml|
  yaml = xml.sub(/\.xml\z/, ".yaml")

  fresh = begin
    yaml_for(xml)
  rescue StandardError => e
    warn "Conversion failed for #{xml}: #{e.message}"
    failed += 1
    next
  end

  if fresh.nil?
    warn "Conversion failed for #{xml}: unrecognized structure"
    failed += 1
    next
  end

  if File.exist?(yaml) && File.read(yaml, encoding: "utf-8") == fresh
    up_to_date += 1
  else
    File.write(yaml, fresh)
    converted += 1
  end
end

puts "bibxml→yaml: wrote #{converted}, unchanged #{up_to_date}, failed #{failed}"
