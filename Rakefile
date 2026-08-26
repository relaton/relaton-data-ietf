# frozen_string_literal: true

require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:spec)

task default: :spec

namespace :index do
  desc 'Full-corpus verification of the published index (slow, minutes) — not part of `rake`'
  task :verify do
    require_relative 'tasks/verify_index'
    VerifyIndex.run
  end
end
