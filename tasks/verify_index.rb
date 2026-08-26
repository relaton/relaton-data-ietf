# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require 'yaml'
require 'relaton'
require 'relaton/ietf'
require 'pubid/ietf'

# Full-corpus verification of the index the crawl published.
#
# The index is written by `Relaton::Ietf::DataFetcher` during the crawl, so
# there is nothing here to rebuild and compare against; what this checks is that
# what was published is internally consistent and actually loadable by a
# consumer — every record indexed, every row well-formed, every id a parseable
# pubid that round-trips and sorts, every :file present, and the whole thing
# readable back through Relaton::Index with pubid_class.
#
# Handles either index generation. `Relaton::Ietf::DataFetcher` is being
# switched from the plain-string `index-v1` to the pubid `index-v2` as a straight
# replacement, so exactly one of the two exists at a time; the pubid checks
# (round-trip, sort key, structured `_type`) only apply to v2 and are reported as
# skipped against v1.
#
# Deliberately not an rspec example: it takes minutes, so it must be opt-in.
module VerifyIndex
  ROOT = File.expand_path('..', __dir__)
  # Preferred first. DataFetcher writes one or the other, never both.
  INDEX_NAMES = %w[index-v2.yaml index-v1.yaml].freeze
  # Ids whose resolution is the point of the whole exercise. DataFetcher
  # downcases filenames, so these are the post-migration names.
  SPOT_CHECKS = {
    'RFC 3986' => 'data/rfc3986.yaml',
    'STD 66' => 'data/std0066.yaml',
    'BCP 9' => 'data/bcp0009.yaml',
    'draft-ietf-quic-transport-34' => 'data/draft-ietf-quic-transport-34.yaml',
    'draft-ietf-quic-transport' => 'data/draft-ietf-quic-transport.yaml',
  }.freeze

  module_function

  def run
    @failures = []
    name = INDEX_NAMES.find { |n| File.exist?(File.join(ROOT, n)) }
    unless name
      abort "no #{INDEX_NAMES.join(' or ')} — run `bundle exec ruby crawler.rb` " \
            '(the index is a crawl output; nothing else writes it)'
    end

    @index_name = name
    @pubid = name.start_with?('index-v2')
    committed = File.join(ROOT, name)
    puts "index: #{name}#{@pubid ? '' : ' (plain-string v1 — pubid checks skipped)'}"

    records = Dir[File.join(ROOT, 'data', '*.yaml')].size
    puts "corpus: #{records} records"

    rows = check_rows committed, records

    # Copy, never the repo's own file: on an index it cannot parse,
    # Relaton::Index's loader DELETES the file it was pointed at.
    Dir.mktmpdir do |scratch|
      FileUtils.cp committed, File.join(scratch, name)
      File.symlink File.join(ROOT, 'data'), File.join(scratch, 'data')
      timed('load through Relaton::Index') { check_loadable scratch, rows }
    end

    report
  end

  # Every way a record can fail to reach the index drops exactly one row, so
  # equality with the record count *is* 'zero records skipped'.
  def check_completeness(rows, records)
    return if rows == records

    fail_with "#{records - rows} record(s) did not reach the index " \
              "(#{rows} rows for #{records} records). Re-run the crawl and read " \
              'the [relaton-ietf] warnings for the reason of each skip.'
  end

  def check_rows(fresh, records)
    rows = YAML.safe_load_file(fresh, permitted_classes: [Symbol])
    check_completeness rows.size, records

    shapes = rows.reject { |r| r.keys.sort == %i[file id] }
    fail_with "#{shapes.size} row(s) are not exactly {:id, :file}; " \
              'Relaton::Index rejects the whole index for any third key' unless shapes.empty?

    # Generation-independent: every row must point at a file that is really
    # there, exactly once, and every record must be reachable.
    missing = rows.reject { |r| File.exist?(File.join(ROOT, r[:file])) }
    fail_with "#{missing.size} row(s) point at a file that does not exist, " \
              "e.g. #{missing.first[:file]}" unless missing.empty?

    files = rows.map { |r| r[:file] }
    fail_with "#{files.size - files.uniq.size} duplicate :file value(s)" if files.uniq.size != files.size
    fail_with "row count #{rows.size} != record count #{records}" if rows.size != records

    # The rest is about the pubid shape, which a v1 index does not have.
    return rows.size unless @pubid

    types = rows.map { |r| r[:id]['_type'] }.uniq
    stray = types.reject { |t| t.to_s.start_with?('pubid:ietf:') }
    fail_with "non-IETF ids in the index: #{stray.inspect}" unless stray.empty?
    puts "types: #{types.sort.join(', ')}"

    check_ids rows
    rows.size
  end

  # Two properties the index loader depends on and never enforces: every id must
  # round-trip through from_hash/to_hash, and every id must expose a non-empty
  # `root.number`, which is the key both the sort and the bsearch narrowing use.
  # An identifier family with a nil number keys every one of its rows to '',
  # collapsing them into one bucket so the bsearch buys nothing.
  def check_ids(rows)
    bad_trip = []
    empty_key = []
    keys = []

    rows.each do |row|
      id = ::Pubid::Ietf::Identifier.from_hash(row[:id])
      bad_trip << row if id.to_hash != row[:id]
      key = id.root.number.to_s
      empty_key << row if key.empty?
      keys << key
    end

    fail_with "#{bad_trip.size} id(s) do not round-trip, e.g. #{bad_trip.first[:id].inspect}" unless bad_trip.empty?
    fail_with "#{empty_key.size} id(s) have an empty bsearch key, e.g. #{empty_key.first[:id].inspect}" unless empty_key.empty?
    fail_with 'index is not sorted by root.number.to_s' unless keys == keys.sort
    puts "ids: #{rows.size} round-tripped, #{keys.uniq.size} distinct bsearch keys"
  end

  # The point of the whole exercise: what was written has to survive the load
  # path Relaton::Index takes, pubid_class and all. Run against the scratch
  # copy — on a malformed index the loader DELETES the file it was pointed at.
  def check_loadable(scratch, rows)
    Dir.chdir(scratch) do
      index = Relaton::Index.find_or_create(
        :IETF_VERIFY, file: @index_name, **(@pubid ? { pubid_class: ::Pubid::Ietf::Identifier } : {})
      )
      fail_with "loaded #{index.index.size} rows, expected #{rows}" if index.index.size != rows

      SPOT_CHECKS.each do |ref, file|
        query = @pubid ? ::Pubid::Ietf::Identifier.parse(ref) : ref
        found = index.search(query).first
        if found.nil?
          fail_with "#{ref} resolves to nothing"
        elsif found[:file] != file
          fail_with "#{ref} resolves to #{found[:file]}, expected #{file}"
        end
      end
    end
  ensure
    Relaton::Index.close :IETF_VERIFY
  end

  def timed(label)
    started = Time.now
    result = yield
    puts format('%-28s %6.1fs', label, Time.now - started)
    result
  end

  def fail_with(message)
    @failures << message
  end

  def report
    if @failures.empty?
      puts "\nindex-v2.yaml verified.'
    else
      @failures.each { |f| warn 'FAIL: #{f}' }
      abort '\n#{@failures.size} check(s) failed."
    end
  end
end
