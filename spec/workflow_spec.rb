# frozen_string_literal: true

# crawler.yml is Cimas-generated, so it is not edited here — but this repo was
# found a full sync behind, missing the `permissions:` block the shared template
# has carried since relaton/support added it. That is not hardening: a caller
# granting less caps what the called workflow gets, so without it the crawl runs
# to completion and then fails on the push, throwing the whole corpus away.
# Cheap to pin, and it fails loudly if the repo drifts behind again.
RSpec.describe ".github/workflows/crawler.yml" do
  let(:path) { File.join(ROOT, ".github/workflows/crawler.yml") }
  let(:workflow) { YAML.safe_load(File.read(path), aliases: true) }

  it "grants the crawl write access so its push can succeed" do
    expect(workflow["jobs"]["crawl"]["permissions"]).to eq("contents" => "write")
  end

  it "calls the shared reusable workflow" do
    expect(workflow["jobs"]["crawl"]["uses"])
      .to eq "relaton/support/.github/workflows/crawler.yml@main"
  end

  # The crawl is expensive (a full rsync of the bibxml-ids mirror plus ~177k
  # records), so it must stay cron/dispatch only — never push or pull_request.
  it "runs only on a schedule or by hand" do
    # `on:` parses as the boolean true in YAML 1.1.
    expect(workflow[true].keys).to contain_exactly("schedule", "workflow_dispatch")
  end
end
