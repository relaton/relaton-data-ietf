# frozen_string_literal: true

require "tmpdir"
require_relative "../tasks/verify_index"
require_relative "../crawler"

RSpec.describe VerifyIndex do
  # `report` once held a string literal that ran across both branches, so it
  # printed that literal and returned whatever the checks found.
  describe ".report" do
    after { described_class.instance_variable_set :@failures, nil }

    it "aborts when a check failed" do
      described_class.instance_variable_set :@failures, ["index-v2.yaml has 0 rows"]

      expect { described_class.report }
        .to raise_error(SystemExit)
        .and output(/FAIL: index-v2\.yaml has 0 rows.*1 check\(s\) failed/m).to_stderr
    end

    it "passes when every check held" do
      described_class.instance_variable_set :@failures, []
      described_class.instance_variable_set :@verified, %w[index-v2.yaml index-v1.yaml]

      expect { described_class.report }
        .to output(/index-v2\.yaml, index-v1\.yaml verified/).to_stdout
    end
  end

  describe ".fail_with" do
    it "names the index a failure belongs to" do
      described_class.instance_variable_set :@failures, []
      described_class.instance_variable_set :@index_name, "index-v1.yaml"

      described_class.fail_with "3 duplicate :file value(s)"

      expect(described_class.instance_variable_get(:@failures))
        .to eq ["index-v1.yaml: 3 duplicate :file value(s)"]
    end
  end

  # Both indexes built by the crawler's own functions over one crawled RFC
  # and one static draft, then verified end to end.
  describe ".run" do
    around do |example|
      Dir.mktmpdir do |root|
        @root = root
        Dir.chdir(root) { example.run }
      end
    end

    before do
      stub_const "VerifyIndex::ROOT", @root
      stub_const "VerifyIndex::SPOT_CHECKS",
                 "RFC 3986" => "data/rfc3986.yaml", "draft-x-04" => "static/draft-x-04.yaml"
    end

    after do
      Relaton::Index.close :IETF
      Relaton::Index.close :IETF_V1
      Relaton::Index.close :IETF_VERIFY
    end

    def write(dir, name, primary, type)
      FileUtils.mkdir_p File.join(@root, dir)
      File.write File.join(@root, dir, "#{name}.yaml"),
                 { "id" => name, "docidentifier" => [{ "content" => primary, "type" => type, "primary" => true }] }.to_yaml
    end

    def build_indexes
      write "data", "rfc3986", "RFC 3986", "IETF"
      write "static", "draft-x-04", "draft-x-04", "Internet-Draft"
      Relaton::Index.find_or_create(
        :IETF, url: nil, file: IetfCrawler::INDEXFILE, pubid_class: Pubid::Ietf::Identifier
      ).add_or_update Pubid::Ietf::Identifier.parse("RFC 3986"), "data/rfc3986.yaml"
      IetfCrawler.index_static_v2
      IetfCrawler.write_index_v1
    end

    def drop_static_row(name)
      rows = YAML.safe_load_file(name, permitted_classes: [Symbol])
      File.write name, rows.reject { |r| r[:file].start_with?("static/") }.to_yaml
    end

    # index-v2 only: relaton's raw loader calls `.root` on every id, so it
    # cannot load the plain-string index-v1 through check_loadable.
    context "on index-v2" do
      before { stub_const "VerifyIndex::INDEX_NAMES", ["index-v2.yaml"] }

      it "passes with the static row" do
        build_indexes

        expect { described_class.run }
          .to output(/corpus: 2 records \(data\/ 1, static\/ 1\).*index-v2\.yaml verified/m).to_stdout
      end

      it "fails when the static row is missing" do
        build_indexes
        drop_static_row "index-v2.yaml"

        expect { described_class.run }
          .to raise_error(SystemExit)
          .and output(/index-v2\.yaml: 1 record\(s\) did not reach the index/).to_stderr
          .and output.to_stdout
      end
    end

    context "on the index-v1 rows" do
      before do
        described_class.instance_variable_set :@failures, []
        described_class.instance_variable_set :@index_name, "index-v1.yaml"
        described_class.instance_variable_set :@pubid, false
      end

      it "passes with the static row" do
        build_indexes

        expect(described_class.check_rows("index-v1.yaml", 2)).to eq 2
        expect(described_class.instance_variable_get(:@failures)).to eq []
      end

      it "fails when the static row is missing" do
        build_indexes
        drop_static_row "index-v1.yaml"

        described_class.check_rows("index-v1.yaml", 2)
        expect(described_class.instance_variable_get(:@failures))
          .to include(/index-v1\.yaml: 1 record\(s\) did not reach the index/)
      end
    end
  end

  describe ".index_names" do
    around do |example|
      Dir.mktmpdir do |root|
        @root = root
        example.run
      end
    end

    before { stub_const "VerifyIndex::ROOT", @root }

    it "verifies every index the crawl published, not only the first" do
      File.write File.join(@root, "index-v1.yaml"), "--- []\n"
      File.write File.join(@root, "index-v2.yaml"), "--- []\n"

      expect(described_class.index_names).to eq %w[index-v2.yaml index-v1.yaml]
    end
  end
end
