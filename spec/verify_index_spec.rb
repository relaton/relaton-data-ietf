# frozen_string_literal: true

require_relative "../tasks/verify_index"

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
