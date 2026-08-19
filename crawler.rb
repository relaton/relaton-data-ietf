# frozen_string_literal: true

# Parses and combines the authoritative IETF bibliographic corpora
# published by IETF Tools (in their older Relaton v1 format) into this
# repo's data/, converted to the current v3 model shape:
#
#   ietf-tools/relaton-data-rfcs          data/RFC*.yaml
#   ietf-tools/relaton-data-ids           data/draft-*.yaml
#   ietf-tools/relaton-data-rfcsubseries  data/BCP*|STD*|FYI*.yaml
#
# Conversion: legacy hash -> Relaton::Bib::HashParserV1 (the upstream
# v1 adapter) -> Relaton::Ietf::ItemData -> v3 YAML. Writes only on
# content change, so an unchanged corpus produces no git churn.
#
# The legacy bibxml XML mirror also under data/ is frozen (the classic
# host retired 2024) and is not indexed: the Pages build reads YAML
# only.

require 'fileutils'
require 'tmpdir'
require 'relaton'
require 'relaton/bib/hash_parser_v1'
require 'yaml'

SOURCES = {
  'relaton-data-rfcs' => 'https://github.com/ietf-tools/relaton-data-rfcs',
  'relaton-data-ids' => 'https://github.com/ietf-tools/relaton-data-ids',
  'relaton-data-rfcsubseries' => 'https://github.com/ietf-tools/relaton-data-rfcsubseries',
}.freeze

def refresh_clone(repo, url)
  dir = File.join(Dir.tmpdir, "ietf-combine-#{repo}")
  if Dir.exist?(File.join(dir, '.git'))
    ok = system('git', '-C', dir, 'fetch', '--depth', '1', 'origin', 'main',
                out: File::NULL) &&
         system('git', '-C', dir, 'reset', '--hard', 'FETCH_HEAD',
                out: File::NULL)
  else
    FileUtils.rm_rf(dir)
    ok = system('git', 'clone', '--depth', '1', '--branch', 'main', url, dir,
                out: File::NULL)
  end
  ok ? dir : nil
end

# Full YAML timestamps parse into Date/Time objects while month-only
# dates ("1969-07") stay Strings — the models cannot round-trip the mix.
# Force every date to its String form before the parser sees it.
def stringify_dates!(obj)
  case obj
  when Hash
    obj.each { |k, v| obj[k] = stringify_dates!(v) }
    obj
  when Array
    obj.map! { |v| stringify_dates!(v) }
    obj
  when Date, Time then obj.iso8601
  else obj
  end
end

def load_v1(path)
  hash = YAML.safe_load_file(path, permitted_classes: [Date, Time], aliases: true)
  stringify_dates!(hash)
  Relaton::Bib::HashParserV1.hash_to_bib(hash)
end

def to_v3_yaml(path)
  norm = load_v1(path)
  recast_flavor(norm)
  Relaton::Ietf::ItemData.new(**norm).to_yaml
end

# HashParserV1 materializes sub-objects as the base Bib classes; the
# Ietf models demand their own subclasses. A to_hash/from_hash round
# trip re-casts the whole subtree (relations are recursive — their
# embedded bibitems carry relations too).
def recast_flavor(norm)
  norm[:ext] = Relaton::Ietf::Ext.from_hash(norm[:ext].to_hash) if norm[:ext]
  return unless norm[:relation]

  norm[:relation] = norm[:relation].map do |rel|
    Relaton::Ietf::Relation.from_hash(rel.to_hash)
  end
end

# Relation targets use inconsistent casing against the referenced
# document's own docid (dyndNS vs dyndns), so keying is case-insensitive.
def squish(id)
  id.to_s.gsub(/[\s.]/, '').downcase
end

def primary_docid(norm)
  ids = norm[:docidentifier]
  (ids.find { |d| d.respond_to?(:primary) && d.primary } || ids.first)&.content
end

def doc_date(norm)
  dates = (norm[:date] || []).filter_map { |d| d.at&.to_s }
  dates.max
end

def doc_doctype(norm)
  norm[:ext]&.doctype&.content
end

def doc_source(norm)
  norm[:source] if norm[:source]&.any?
end

def constituent_ids(norm)
  (norm[:relation] || []).select { |r| r.type == 'includes' }.flat_map do |rel|
    next [] unless rel.bibitem

    ids = rel.bibitem.docidentifier rescue []
    id = (ids.find { |d| d.primary } || ids.first)&.content if ids&.any?
    id ||= rel.bibitem.formattedref&.content if rel.bibitem.respond_to?(:formattedref)
    id ? [id] : []
  end
end

# Unversioned draft aliases and BCP/STD/FYI groups are thin records:
# the properties live in their underlying documents. They inherit the
# date, doctype and source links of their NEWEST `includes` constituent.
def inherit_metadata!(undated, meta)
  fixed = 0
  undated.each do |path, dest|
    norm = load_v1(path)
    recast_flavor(norm)
    newest_meta = constituent_ids(norm)
                    .filter_map { |id| meta[squish(id)] }
                    .max_by { |m| m[:date] }
    next unless newest_meta && newest_meta[:date]

    norm[:date] = [Relaton::Bib::Date.new(type: ['published'], at: newest_meta[:date])]
    if doc_doctype(norm).nil? && newest_meta[:doctype]
      ext_hash = norm[:ext] ? norm[:ext].to_hash : {}
      ext_hash['doctype'] = { 'content' => newest_meta[:doctype] }
      norm[:ext] = Relaton::Ietf::Ext.from_hash(ext_hash)
    end
    norm[:source] ||= Marshal.load(Marshal.dump(newest_meta[:source])) if newest_meta[:source]

    fresh = Relaton::Ietf::ItemData.new(**norm).to_yaml
    File.write(dest, fresh)
    if (id = primary_docid(norm))
      key = squish(id)
      old = meta[key]
      meta[key] = { date: [old&.dig(:date), newest_meta[:date]].compact.max,
                    doctype: doc_doctype(norm) || old&.dig(:doctype),
                    source: norm[:source] || old&.dig(:source) }
    end
    fixed += 1
  rescue StandardError => e
    warn "Metadata inheritance failed for #{path}: #{e.message}"
  end
  puts "metadata inheritance: fixed #{fixed} of #{undated.size}"
end

def combine(repo, url, docid_dates)
  dir = refresh_clone(repo, url) or raise "clone failed: #{repo}"

  converted = unchanged = failed = 0
  undated = []
  Dir[File.join(dir, 'data', '*.yaml')].sort.each do |src|
    dest = File.join(__dir__, 'data', File.basename(src))
    norm = nil
    fresh = begin
      norm = load_v1(src)
      recast_flavor(norm)
      Relaton::Ietf::ItemData.new(**norm).to_yaml
    rescue StandardError => e
      warn "Conversion failed for #{src}: #{e.message}"
      failed += 1
      next
    end

    if File.exist?(dest) && File.read(dest) == fresh
      unchanged += 1
    else
      File.write(dest, fresh)
      converted += 1
    end

    if (date = doc_date(norm)) && (id = primary_docid(norm))
      key = squish(id)
      prior = docid_dates[key]
      docid_dates[key] = { date: [prior&.dig(:date), date].compact.max,
                           doctype: doc_doctype(norm) || prior&.dig(:doctype),
                           source: doc_source(norm) || prior&.dig(:source) }
    else
      undated << [src, dest]
    end
  end
  puts "#{repo}: wrote #{converted}, unchanged #{unchanged}, failed #{failed}"
  undated
rescue StandardError => e
  warn "#{repo}: #{e.message}"
  []
end


# Flat docid -> file index, same shape the IETF sources publish
# (index-v1.yaml; the shared crawler workflow zips and commits it).
# Consumers fetch it from raw.githubusercontent over the fleet's
# standard baseurl. Rebuilt whole on every run, so removed source
# documents never linger as stale rows.
def build_index
  idx = Relaton::Index.find_or_create :IETF, file: "index-v1.yaml"
  Dir[File.join(__dir__, 'data', '*.yaml')].sort.each do |f|
    doc = YAML.safe_load_file(f, permitted_classes: [Date, Time], aliases: true)
    ids = doc["docidentifier"] || []
    docid = ids.find { |d| d.is_a?(Hash) && d["primary"] } || ids.first
    next unless docid

    idx.add_or_update docid["content"], "data/#{File.basename(f)}"
  end
  idx.save
  puts "index-v1.yaml: #{idx.index.size} entries"
end

t1 = Time.now
puts "Started at: #{t1}"

docid_dates = {}
undated = SOURCES.flat_map { |repo, url| combine(repo, url, docid_dates) }
# A second pass so groups can inherit from constituents converted in
# any source (BCP/STD/FYI include RFCs from the rfcs repo).
inherit_metadata!(undated, docid_dates)
build_index

t2 = Time.now
puts "Stopped at: #{t2}"
puts "Done in: #{(t2 - t1).round} sec."
