# frozen_string_literal: true

source 'https://rubygems.org'

git_source(:github) { |repo_name| "https://github.com/#{repo_name}" }

# relaton is now a single unpublished gem in the relaton/relaton monorepo
# (relaton-bib et al. were consolidated into it). Pull from main over HTTPS
# so CI clones anonymously. Matches the other relaton-data-* repos.
gem 'relaton', git: 'https://github.com/relaton/relaton.git', branch: 'main'
