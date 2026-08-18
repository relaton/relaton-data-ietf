#!/usr/bin/env ruby
# frozen_string_literal: true

# Builds the unified index (index.yaml + index.zip + last_modified.txt)
# for relaton-data-ietf. Stdlib only. Key semantics follow the corpus
# doctrine: undated strips every colon-year; IETF ids carry no part.
# Cross-references: each STD/BCP/FYI id is added as a lookup variant of
# every RFC it includes.

require "yaml"
require "zlib"
require "json"

ROOT = File.expand_path("..", __dir__)
STREAMS = %w[rfcs rfcsubseries ids misc].freeze

def docids_of(doc)
  list = doc["docidentifier"] || doc["docid"] || []
  list.filter_map do |d|
    id = d["content"] || d["id"]
    id ? { "id" => id, "type" => d["type"], "primary" => d["primary"] ? true : false } : nil
  end
end

def published_of(doc)
  (doc["date"] || []).each do |d|
    next unless d["type"] == "published"
    return d["at"] || d["value"] || d["on"]
  end
  nil
end

entries = []
constituents = Hash.new { |h, k| h[k] = [] }

STREAMS.each do |stream|
  Dir[File.join(ROOT, "data", stream, "*.yaml")].sort.each do |path|
    doc = begin
      YAML.safe_load(File.read(path), aliases: true) || {}
    rescue StandardError
      {}
    end
    docids = docids_of(doc)
    primary = docids.find { |d| d["primary"] } || docids.first
    next unless primary

    title = (doc["title"] || []).find { |t| t["type"] == "main" } || (doc["title"] || []).first
    published = published_of(doc)
    norm = primary["id"].upcase.delete(" ")

    if stream == "rfcsubseries"
      (doc["relation"] || []).each do |rel|
        next unless rel["type"] == "includes"
        inc = (rel["bibitem"] || {})["docidentifier"]
        inc_id = inc.is_a?(Array) ? inc.first&.[]("content") || inc.first&.[]("id") : inc
        constituents[inc_id.to_s.upcase.delete(" ")] << primary["id"] if inc_id
      end
    end

    entries << {
      "id" => primary["id"],
      "stream" => stream,
      "file" => path.delete_prefix("#{ROOT}/"),
      "docids" => docids,
      "title" => title && title["content"],
      "year" => published.to_s[0, 4],
      "published" => published,
      "doctype" => doc["type"],
      "status" => doc["status"],
    }
  end
end

entries.each do |e|
  norm = e["id"].upcase.delete(" ")
  extra = constituents[norm].uniq - [e["id"]]
  extra.each { |x| e["docids"] << { "id" => x, "type" => "IETF", "primary" => false } }
  e["keys"] = {
    "norm" => norm,
    "undated" => norm.gsub(/:?(?:19|20)\d{2}(?=[^-]*$)/, ""),
    "allparts" => norm.gsub(/:?(?:19|20)\d{2}(?=[^-]*$)/, ""),
  }
end

File.write(File.join(ROOT, "index.yaml"), YAML.dump(entries))
Zlib::GzipWriter.open(File.join(ROOT, "index.zip")) { |gz| gz.write(YAML.dump(entries)) }
File.write(File.join(ROOT, "last_modified.txt"), Time.now.httpdate)
puts "index: #{entries.size} entries, #{constituents.values.flatten.uniq.size} cross-refs"
