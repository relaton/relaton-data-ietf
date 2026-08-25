# relaton-data-ietf

The IETF corpus (RFCs, Internet-Drafts, RFC sub-series) as Relaton v3 YAML,
crawled by `Relaton::Ietf::DataFetcher` straight from the authoritative sources,
plus the pubid-structured `index-v2.yaml` the fetcher writes alongside it.

`main` is the default branch. `v2` is four years stale — it holds only the
retired bibxml XML mirror and the old xml2rfc downloader. Do not work from it.

## Layout

| Path | What |
|---|---|
| `crawler.rb` | rsyncs the drafts mirror, clears the outputs, runs the three fetches |
| `data/*.yaml` | ~177k v3 records, flat, lower-cased filenames |
| `index-v2.yaml` / `.zip` | The document index, written by DataFetcher during the crawl |
| `bibxml-ids/` | Local rsync mirror the drafts fetch reads. Gitignored |
| `tasks/verify_index.rb` | Full-corpus verification behind `rake index:verify` |

## Development

`relaton` and `pubid` are both tracked from git `main` — neither carries what
this repo needs in a release. `Gemfile.lock` is gitignored, so every
`bundle install` and CI run re-resolves them.

To build against an unmerged relaton, do **not** edit the Gemfile. Use Bundler's
local override, which lives in the gitignored `.bundle/`:

```sh
bundle config set --local disable_local_branch_check true
bundle config set --local local.relaton /path/to/relaton/worktree
```

`Relaton::Ietf::DataFetcher` is not loaded by `require "relaton"` — it needs
`require "relaton/ietf/data_fetcher"` explicitly.

**You cannot run the crawl from a network-restricted sandbox.** It needs
`www.rfc-editor.org` over HTTPS and `rsync.ietf.org` on port 873 (a public,
anonymous rsync daemon module — no credentials). Only CI or an unrestricted
machine can exercise it end to end.

## Invariants that are expensive to rediscover

**The crawl must run from the repository root.** `DataFetcher` globs
`bibxml-ids/*.xml` and writes its index relative to the working directory.
`IetfCrawler.run` pins CWD itself.

**The crawl is destructive, and has to be.** `DataFetcher` only adds records,
and `Relaton::Index` accumulates on top of any index file it finds. Without
clearing `data/` and `index*` first, every run publishes the union of all runs —
including records for documents withdrawn upstream.

**Nothing here derives metadata.** Thin records — unversioned draft aggregators
and BCP/STD/FYI groups — have no date, doctype or source of their own, because
`rfc-index.xml` publishes none for a sub-series (`<bcp-entry>` is a `<doc-id>`
plus an `<is-also>`, nothing more) and the aggregator is synthesised rather than
fetched. They inherit from their newest constituent **inside the gem**
(relaton#120). This repo used to patch that up in a second pass; that code is
gone and must not come back.

**Nothing here writes the `.zip`.** relaton/support's shared `crawler.yml` zips
any changed `index*.yaml` and commits both.

**CI stages only `index*.yaml` and `data/*`.** Anything the crawl writes
elsewhere is never committed — worth knowing before adding a state file.

**Nothing in `data/` may look like a stray document.** relaton-cli's site
generator globs `data/**/*.{yaml,yml}` and treats any mapping with an `id`,
`docidentifier` or `title` key as a bibliographic record, which would publish a
phantom document on the Pages site.

**`Relaton::Index` deletes an index it cannot parse.** With no `url:`,
`FileIO#load_index` on a malformed index calls `remove` → `File.delete`. Never
point `find_or_create` at the repo's own index to validate it — copy it to a
scratch directory first. `tasks/verify_index.rb` does this; a spec that forgot
would delete the artifact it was meant to guard.

**The crawler refuses to publish a shrinking corpus.** `data/` has already been
cleared by the time the fetches run, so a crawl that reaches the network but
comes back short would otherwise be committed as the whole corpus. The floor is
99% of the count committed in git; `--allow-shrink` overrides it.

**Filenames are lower-cased** by `Core::DataFetcher#output_file`. The migration
from the old upper-cased names is a case-only rename, which a case-insensitive
filesystem cannot represent — `reset_outputs` deleting `data/` wholesale is what
makes git see deletes plus adds instead.

## Workflows

`crawler.yml`, `check-index.yml`, `deploy.yml` and `keep-alive.yml` are all
Cimas-generated — edit them in `relaton/support`'s `cimas-config/`, never here.
This repo was once a full sync behind on `crawler.yml`, missing the
`permissions: contents: write` block without which the crawl completes and then
fails on the push; `spec/workflow_spec.rb` pins it so that cannot recur silently.

`test.yml` is this repo's own and is not Cimas-mapped.
