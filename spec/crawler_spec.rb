# frozen_string_literal: true

require "tmpdir"
require_relative "../crawler"

RSpec.describe IetfCrawler do
  describe ".parse_args" do
    it "defaults to a full crawl that must not shrink" do
      expect(described_class.parse_args([]))
        .to eq(skip_rsync: false, allow_shrink: false)
    end

    it "recognizes --skip-rsync" do
      expect(described_class.parse_args(["--skip-rsync"])).to include(skip_rsync: true)
    end

    it "recognizes --allow-shrink" do
      expect(described_class.parse_args(["--allow-shrink"])).to include(allow_shrink: true)
    end

    # The workflow passes `inputs.args` through verbatim, so a typo must not
    # degrade into a run that looks successful.
    it "aborts on an unrecognized argument rather than ignoring it" do
      expect { described_class.parse_args(["--skiprsync"]) }
        .to raise_error(SystemExit).and output(/--skiprsync/).to_stderr
    end
  end

  describe "the crawl" do
    around do |example|
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p File.join(root, "data")
        @root = root
        example.run
      end
    end

    before do
      stub_const "IetfCrawler::ROOT", @root
      allow(described_class).to receive(:sync_drafts)
      allow(described_class).to receive(:committed_record_count).and_return(0)
      allow(Relaton::Ietf::DataFetcher).to receive(:fetch)
    end

    it "fetches every DataFetcher source" do
      described_class.run([])

      described_class::SOURCES.each do |source|
        expect(Relaton::Ietf::DataFetcher).to have_received(:fetch).with(source)
      end
    end

    # The drafts fetch reads bibxml-ids/ off disk and does no fetching of its
    # own, so a crawl that fetched before syncing would silently produce zero
    # Internet-Drafts.
    it "syncs the drafts mirror before fetching" do
      calls = []
      allow(described_class).to receive(:sync_drafts) { calls << :rsync }
      allow(Relaton::Ietf::DataFetcher).to receive(:fetch) { |s| calls << s }

      described_class.run([])

      expect(calls.first).to eq :rsync
      expect(calls.drop(1)).to eq described_class::SOURCES
    end

    it "skips the rsync when asked" do
      described_class.run(["--skip-rsync"])

      expect(described_class).not_to have_received(:sync_drafts)
    end

    # DataFetcher only ever adds, and Relaton::Index accumulates on top of any
    # index file it finds, so a crawl that did not clear both would publish the
    # union of every run rather than a snapshot.
    describe "resetting the outputs" do
      it "clears stale records and any existing index" do
        File.write File.join(@root, "data", "gone.yaml"), "id: gone\n"
        File.write File.join(@root, "index-v2.yaml"), "--- []\n"
        File.write File.join(@root, "index-v2.zip"), "not really a zip\n"

        Dir.chdir(@root) { described_class.reset_outputs }

        expect(File).not_to exist(File.join(@root, "data", "gone.yaml"))
        expect(File).not_to exist(File.join(@root, "index-v2.yaml"))
        expect(File).not_to exist(File.join(@root, "index-v2.zip"))
        expect(Dir).to exist(File.join(@root, "data"))
      end
    end
  end

  # reset_outputs has already emptied data/ by the time the fetches run, so a
  # crawl that reaches the network but comes back short would otherwise be
  # committed as the whole corpus.
  describe ".check_yield" do
    around do |example|
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p File.join(root, "data")
        @root = root
        Dir.chdir(root) { example.run }
      end
    end

    def produce(count)
      count.times { |i| File.write File.join(@root, "data", "rfc#{i}.yaml"), "id: #{i}\n" }
    end

    it "passes when the corpus held its size" do
      produce 100
      expect { described_class.check_yield(100) }.not_to raise_error
    end

    it "passes when the corpus grew" do
      produce 120
      expect { described_class.check_yield(100) }.not_to raise_error
    end

    it "aborts when the crawl came back short" do
      produce 40
      expect { described_class.check_yield(100) }
        .to raise_error(SystemExit).and output(/40 records, down from the 100/).to_stderr
    end

    it "passes on a first crawl, when nothing is committed yet" do
      produce 3
      expect { described_class.check_yield(0) }.not_to raise_error
    end

    it "publishes a genuine shrink when it is declared" do
      produce 40
      expect { described_class.check_yield(100, allow_shrink: true) }.not_to raise_error
    end
  end

  describe ".sync_drafts" do
    it "aborts when rsync fails, rather than fetching from an empty mirror" do
      allow(described_class).to receive(:system).and_return(false)

      expect { described_class.sync_drafts }
        .to raise_error(SystemExit).and output(/rsync/).to_stderr
    end
  end
end
