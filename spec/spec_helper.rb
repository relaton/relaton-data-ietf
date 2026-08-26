# frozen_string_literal: true

require "yaml"
require "relaton"
require "relaton/ietf"
require "pubid"
require "pubid/ietf"

RSpec.configure do |config|
  config.example_status_persistence_file_path = "spec/examples.txt"
  config.disable_monkey_patching!
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end

# Repo root — the crawl writes data/ and its index here.
ROOT = File.expand_path("..", __dir__)
