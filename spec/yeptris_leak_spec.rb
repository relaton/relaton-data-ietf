# frozen_string_literal: true

# relaton serializes every record through the yeptris Psych drop-in. From
# yeptris 0.6.28.4 its native materializer leaks native memory on every dump
# and load (leptris/yeptris-ruby#259): about 45 KB a `to_yaml`, never returned
# to GC. A crawl writes ~179k records, so the runner is killed before it ends.
# The Gemfile pins yeptris below 0.6.28.4; this guards the pin, and tells
# whoever lifts it whether the release they moved to is fixed.
RSpec.describe "YAML serialization memory", if: File.exist?("/proc/self/status") do
  def rss_mb
    File.read("/proc/self/status")[/VmRSS:\s+(\d+)/, 1].to_i / 1024
  end

  it "does not grow with the number of records serialized" do
    record = { "id" => "RFC 3986", "abstract" => "y" * 1000,
               "docidentifier" => [{ "content" => "RFC 3986", "type" => "IETF", "primary" => true }] }
    500.times { record.to_yaml }
    GC.start
    before = rss_mb

    5000.times { YAML.safe_load(record.to_yaml) }
    GC.start

    # A leaking build grows by ~300 MB here; a sound one by a few MB.
    expect(rss_mb - before).to be < 50
  end
end
