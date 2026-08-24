# frozen_string_literal: true

source 'https://rubygems.org'

git_source(:github) { |repo_name| "https://github.com/#{repo_name}" }

# relaton is now a single unpublished gem in the relaton/relaton monorepo
# (relaton-bib et al. were consolidated into it). Pull from main over HTTPS
# so CI clones anonymously. Matches the other relaton-data-* repos.
gem 'relaton', git: 'https://github.com/relaton/relaton.git', branch: 'main'

# `Pubid::Ietf` is in no released pubid: the flavor was added after
# 2.0.0.pre.alpha.8, and the fixes the index depends on — draft slugs
# containing `.` or uppercase, zero-padded sub-series (`STD0066` -> `STD 66`),
# and the draft slug living in `number` so the index sort key is non-empty —
# landed after the 2.0.0.pre.alpha.9 bump. relaton.gemspec's
# `pubid ~> 2.0.0.pre.alpha.8` would otherwise resolve to that release and
# build_index could not parse a single identifier.
#
# TODO: drop once these ship in a pubid release.
gem 'pubid', git: 'https://github.com/metanorma/pubid.git', branch: 'main'
