# frozen_string_literal: true

# Crawls the IETF bibliographic corpus straight from the authoritative sources
# into this repo's data/, as Relaton v3 YAML:
#
#   ietf-rfc-entries      www.rfc-editor.org/rfc-index.xml  <rfc-entry>
#   ietf-rfcsubseries     the same index, <bcp|fyi|std-entry>
#   ietf-internet-drafts  rsync.ietf.org::bibxml-ids, parsed from bibxml-ids/
#
# All three are `Relaton::Ietf::DataFetcher` sources, so the records are v3
# natively and `index-v2.yaml` — the pubid-structured index consumers download
# — is written by the fetcher as the crawl runs. There is no conversion step,
# nothing here builds the index, and nothing here derives metadata: thin
# records (sub-series, unversioned draft aggregators) inherit date, doctype and
# source from their newest constituent inside the gem (relaton#120).
#
# This replaces an earlier design that combined the three ietf-tools/
# relaton-data-* mirrors and converted them from Relaton v1. Those mirrors are
# themselves produced by relaton's own gem from these same two origins, so the
# indirection only ever cost a hop of staleness and a v1 -> v3 round trip.

require 'fileutils'
require 'open3'
require 'relaton'
# Not loaded by `require "relaton"` — the flavor's fetcher is an opt-in entry
# point, reached only by the data repos that crawl.
require 'relaton/ietf/data_fetcher'

module IetfCrawler
  # DataFetcher source keys. Order is not significant: the sub-series fetch
  # builds its own RFC lookup from the same index document rather than reading
  # what the RFC fetch wrote.
  SOURCES = %w[ietf-rfc-entries ietf-rfcsubseries ietf-internet-drafts].freeze

  ROOT = __dir__
  DATA_DIR = 'data'
  # `fetch_ieft_internet_drafts` globs this path relative to the working
  # directory; it does no fetching of its own.
  DRAFTS_MIRROR = 'bibxml-ids'
  RSYNC_SOURCE = 'rsync.ietf.org::bibxml-ids'

  # The fraction of the committed corpus a crawl must still produce to be
  # publishable. Expressed as what is KEPT, so 0.99 allows at most 1% shrinkage.
  MIN_RETENTION = 0.99

  module_function

  # Everything runs with the process CWD pinned to the repository root, because
  # both DataFetcher's `bibxml-ids/` glob and the index file it writes are
  # resolved relative to the working directory.
  def run(argv = ARGV)
    opts = parse_args(argv)
    Dir.chdir(ROOT) { crawl(opts) }
  end

  def crawl(opts)
    t1 = Time.now
    puts "Started at: #{t1}"

    previous = committed_record_count
    sync_drafts unless opts[:skip_rsync]
    reset_outputs
    SOURCES.each { |source| Relaton::Ietf::DataFetcher.fetch(source) }
    check_yield(previous, allow_shrink: opts[:allow_shrink])

    t2 = Time.now
    puts "Stopped at: #{t2}"
    puts "Done in: #{(t2 - t1).round} sec."
  end

  # `--skip-rsync` reuses an already-synced bibxml-ids/ (the mirror is ~167k
  # files, so a re-run while debugging should not re-transfer it).
  # `--allow-shrink` lets a smaller corpus through the yield check.
  # Anything else aborts rather than being ignored: the workflow passes
  # `inputs.args` through verbatim, so a typo would otherwise look like a
  # successful run.
  def parse_args(argv)
    opts = { skip_rsync: false, allow_shrink: false }
    argv.each do |arg|
      case arg
      when '--skip-rsync' then opts[:skip_rsync] = true
      when '--allow-shrink' then opts[:allow_shrink] = true
      when '' then next
      else abort "Unknown argument #{arg.inspect} " \
                 '(usage: crawler.rb [--skip-rsync] [--allow-shrink])'
      end
    end
    opts
  end

  def sync_drafts
    puts "Syncing #{RSYNC_SOURCE} -> #{DRAFTS_MIRROR}/"
    return if system('rsync', '-avcizxL', RSYNC_SOURCE, "./#{DRAFTS_MIRROR}",
                     out: File::NULL)

    abort "rsync of #{RSYNC_SOURCE} failed. Without it the Internet-Draft " \
          'fetch reads an empty directory and silently produces no drafts.'
  end

  # DataFetcher only ever adds: it neither deletes records for documents that
  # went away nor clears the index, and `Relaton::Index` reads whatever index
  # file it finds and accumulates on top of it. So both have to be cleared for
  # a crawl to be a true snapshot rather than a union with every past run.
  def reset_outputs
    FileUtils.rm_rf DATA_DIR
    FileUtils.mkdir_p DATA_DIR
    FileUtils.rm_f Dir['index*']
  end

  # What is committed right now, read from git rather than from disk — the
  # corpus on disk has already been cleared by the time this matters. Counts
  # only: the committed names are the old upper-cased ones and the produced
  # names are lower-cased, so this must never try to match them pairwise.
  def committed_record_count
    out, status = Open3.capture2('git', 'ls-files', '--', "#{DATA_DIR}/*.yaml")
    status.success? ? out.lines.count : 0
  end

  # A crawl that reaches the network but comes back short is the dangerous
  # case: reset_outputs has already emptied data/, so a partial result would be
  # committed as the whole corpus. Aborting makes the workflow step fail, and
  # the shared crawler.yml stages nothing from a failed step.
  def check_yield(previous, allow_shrink: false)
    produced = Dir[File.join(DATA_DIR, '*.yaml')].size
    puts "records: #{produced} (was #{previous})"
    return if allow_shrink || previous.zero? || produced >= previous * MIN_RETENTION

    abort "Refusing to publish: the crawl produced #{produced} records, down " \
          "from the #{previous} committed. A short crawl usually means an " \
          'upstream fetch failed rather than that documents were withdrawn — ' \
          'check the log above. Pass --allow-shrink if the loss is real.'
  end
end

IetfCrawler.run if $PROGRAM_NAME == __FILE__
