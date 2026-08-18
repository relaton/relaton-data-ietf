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

def to_v3_yaml(path)
  hash = YAML.safe_load_file(path, permitted_classes: [Date, Time], aliases: true)
  norm = Relaton::Bib::HashParserV1.hash_to_bib(hash)
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

def combine(repo, url)
  dir = refresh_clone(repo, url) or raise "clone failed: #{repo}"

  converted = unchanged = failed = 0
  Dir[File.join(dir, 'data', '*.yaml')].sort.each do |src|
    dest = File.join(__dir__, 'data', File.basename(src))
    fresh = begin
      to_v3_yaml(src)
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
  end
  puts "#{repo}: wrote #{converted}, unchanged #{unchanged}, failed #{failed}"
rescue StandardError => e
  warn "#{repo}: #{e.message}"
end

t1 = Time.now
puts "Started at: #{t1}"

SOURCES.each { |repo, url| combine(repo, url) }

t2 = Time.now
puts "Stopped at: #{t2}"
puts "Done in: #{(t2 - t1).round} sec."
