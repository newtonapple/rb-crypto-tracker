# AGENTS.md

Working notes for AI agents in this repo. Setup and day-to-day commands live in
`README.md`. Read that first.

## What this project is

A crypto cost-basis tracker. Ruby, Roda, Sequel, PostgreSQL. The web app is an
unused skeleton from the roda-sequel-stack template; all real work happens in
the import/process/report pipeline run from the command line.

## Hard rules

- **Never commit `.dev/`, `.env`, `.env.rb`, `.vscode/`, or `Makefile.dev`.** All
  are gitignored. `.dev/` is the user's private working directory: their exports,
  their automation scripts, their database dumps. `.env` and `.env.rb` hold API
  keys and session secrets. `.ruby-lsp/` ignores its own contents through a
  generated `.ruby-lsp/.gitignore` that is tracked; leave it alone.
- Do not run the local import, process, seed, migration, or report tasks without
  being asked. They write to the development database, and full-import scripts
  typically call `portfolio.delete_transactions!` first, which destroys derived
  accounting data.
- Do not run `bin/db-restore.sh` or any local restore-to-database target. They
  `dropdb` a database.
- Coinbase Exchange API calls hit the live account when credentials are set.
  Use the sandbox host (`https://api-public.sandbox.exchange.coinbase.com`) when
  testing API code.
- Use `CoinbaseExchange::Signature.from_env` in anything new. Do not hardcode
  credentials.

### Dev data and PII

Treat everything under `.dev/` as private, and do not document it in tracked
files. The library docs describe the library. If a detail only makes sense for
this checkout's workflow, it belongs in `.dev/README.md`, which is gitignored.

- Read `.dev/**/*.rb` scripts when you need to know how the local pipeline is
  driven. Do not open the data files they point at (any CSV, PDF, XLSX, IMG, JSON,
  or SQL under `.dev/`). They are dev data, not source.
- Do not name `.dev` scripts, targets, paths, or their contents in README.md,
  AGENTS.md, `docs/`, commits, PRs, issues, or logs. Say "the local import
  scripts" if you must refer to them at all.
- Filter PII and private information out of everything you produce. That includes
  the chat transcript, tool output, terminal scrollback, commit messages, PR
  descriptions, issues, log files, and any file written to disk. Names, emails,
  account ids, wallet addresses, transaction ids, balances, amounts, and dates
  all count.
- Tool output is logged into the session transcript and is hard to retract. A
  `cat` of a `.dev` file, a `psql` dump, or a report run puts dev data there
  permanently. Do not run commands that print raw rows. Prefer counts,
  aggregates, schemas, and `EXPLAIN`.
- When you have to look at data to debug, read the smallest slice that answers
  the question, describe it in prose rather than pasting it, and never repeat raw
  values back.
- Report scripts write holdings and figures to stdout. Redirect that output to a
  file outside the repo, never a committed one, and do not paste the results into
  a commit message or PR description.
- Do not add analytics, telemetry, bug reporters, or any network call that sends
  local data off the machine.

## Layout

See the Layout section in `README.md` for a tree of the tracked source.

## Read the docs first

`docs/` holds the detailed reference, and it is tracked. Read it before
re-deriving anything from source:

- `docs/workflow.md`: the pipeline stages, per-platform importer notes, recovery
  procedures, and a troubleshooting map keyed to real exceptions.
- `docs/data-model.md`: entity-relationship diagram of all 12 tables, the enum
  values, the two tiers of cost columns, and why the composite indexes are wide.
- `docs/accounting.md`: `process!` dispatch, lot selection, disposal math, fee
  handling, transfer matching, and the bankruptcy-loss path.

These sections below are the agent-facing summary. Depth and line citations live
in `docs/`.

## Conventions

- Every tracked file starts with `# frozen_string_literal: true`. The `.dev`
  scripts do not.
- Model files open with a generated schema comment. Regenerate with
  `rake annotate`; do not hand-edit it.
- Importers are plain classes under `module Importers`. Constructor takes
  `account:`, exposes `#parse!(csv_string)` and `#transactions`. They build
  unsaved `Transaction` objects and never write to the DB; the calling script
  saves them.
- Reports print through `TableFormatter` (`render_table` / `print_table`), which
  needs `TABLE_HEADERS`, `TABLE_ALIGNMENTS`, and `table_row` on the model. Add
  all three when a new model needs reporting.
- Money is `BigDecimal`. Use `.to_s('F')` when rendering so exponents never
  appear.
- **Rubocop is the style authority. Run `bundle exec rubocop <files you touched>`
  before finishing, and get them to zero offenses.** Config is `.rubocop.yml`
  (155-char lines, 50-line methods, 250-line classes, `rubocop-sequel` and
  `rubocop-performance`). Do not disable a cop to pass; restructure instead, and
  say in your summary if you had to. The tree has 40 pre-existing offenses across
  15 files, 33 of them `Metrics/*` concentrated in `models/transaction.rb` and
  `models/transfer.rb`. Those are not yours to fix in an unrelated change, and
  not a license to add more: lint the files you touch, never the whole repo.
- The Roda app is frozen outside development (`models.rb`). Code that mutates
  model state at runtime needs the development path.

## Data model

Full reference in [docs/data-model.md](docs/data-model.md). The agent-facing
summary:

`Portfolio` -> `Account` (per platform, with an `accounting_method`) ->
`Transaction` (normalized, one row per platform event) -> derived accounting
rows: `Acquisition` -> `Asset` (lots), `Disposal`, `Transfer` ->
`TransferredAsset`.

`Currency` and `Platform` are `static_cache` reference tables with load-time
lookup hashes (`Currency::BY_SYMBOL`, `Platform::BY_NAME`). Treat them as
read-only. `Currency.by_symbol` raises `FrozenError` for an unknown symbol
rather than returning `nil` (see known issues), so importers that guard with
`currency&.crypto?` do not get the protection they expect.

Enum types are defined in migrations, not in Ruby: `transaction_type`,
`acquisition_type`, `disposal_type`, `capital_gains_treatment`,
`accounting_method`, `currency_type`. Adding a value needs a migration.

`Transaction#process!` is the core state machine. It is not idempotent: it
writes `processed: true` and creates rows. To re-run accounting, use
`Portfolio#reset_transactions!` (unprocess + delete derived rows) rather than
deleting transactions.

Transfers are auto-matched by currency, amount, and a +/- 3 day window
(`Transaction::MAX_TRANSFER_DELTA_SECS`). Zero matches or more than one raises.
Most pipeline failures are here, and the fix is usually a fee adjustment in the
importer, not a wider window.

Two schema traps, easy to get wrong when generating diagrams or queries: the
`transaction_id` columns on `acquisitions` and `disposals` are plain integers, not
foreign keys, while every other `*_id` is a real FK. And
`transactions.from_wallet_id` / `to_wallet_id` reference `account_wallets(id)`,
not `wallets(id)`.

## Working on importers

See [docs/workflow.md](docs/workflow.md) for the header constants each importer
expects. The agent-facing summary:

Platform CSV formats change without notice, and importers key off exact header
strings declared as constants at the top of each class. When an import breaks,
diff the new export's headers against those constants first.

Deduplication is by `platform_transaction_id`, unique per
`(account_id, type, platform_transaction_id)`. Importers build synthetic ids
from type, timestamp, currency, and amount when the platform gives no stable id,
so re-importing a file with changed synthetic ids creates duplicates rather than
updating rows. Scripts rescue `Sequel::ValidationFailed` per row to count
duplicates; keep that pattern.

Local automation scripts come in two shapes: a full import that deletes all
portfolio transactions first, and an incremental import that appends. A
per-platform import deletes only that account's transactions. Keep whichever
shape matches the job.

## Known broken state

Verified on the `dev` branch, so you do not rediscover these:

- `Currency.by_symbol` raises `FrozenError` for a symbol that is not in the
  table. `BY_SYMBOL` is built with a default proc that writes to the hash, then
  `.freeze`d, so a miss tries to mutate a frozen hash. Several importers
  (`blockfi.rb:156`, `coinbase_pro.rb:121`) guard with `currency&.crypto?`
  expecting `nil`, so an unrecognized coin in an export crashes the import
  instead of skipping the row. Fix: `BY_SYMBOL.fetch(symbol, [])`.
- `spec/model/model1_spec.rb` references `Model1` and `spec/web/prefix1_spec.rb`
  exercises the scaffold `routes/prefix1.rb`. Neither model exists; the specs are
  scaffold stubs with empty bodies.
- `Importers::Gemini` hardcodes a snapshot of Gemini's trading-pair table. New
  pairs need manual additions.
- `Transfer#set_account_average_cost!` has `return unless account_cost_amount.nil?
  && account_cost_amount`, which can never assign. Dead code, left in place.
- The `accounting_method` enum includes `spec`, which has no implementation.
  `Asset.disposal_lots` dispatches by method name, so an account set to `spec`
  raises `NoMethodError` on the first disposal.
- `Currency.by_symbol(symbol, type:)` filters on `c.name == type`, comparing a
  full name against `"crypto"`/`"fiat"`. The filter always empties the list and
  the `type:` argument is inert.
- `Transaction#process!` has no branch for most of the `transaction_type` enum.
  `income`, `airdrop`, `staking`, `mining`, `fork`, `gift_received`, `gift_sent`,
  `payment`, `fee`, `loss_investment`, `loss_theft`, `loss_casualty`, and
  `loss_bankruptcy` fall through the `case`, write nothing, and never set
  `processed`, so they sit in `unprocessed_transactions` forever. Add a branch
  when a platform export needs one.
- `seed/fiats.json` contains only USD.

## Running things

Use `bundle exec` for everything. `rackup` is not installed; the server is
`bundle exec falcon`. PostgreSQL must be started manually.

The `rake` tasks in the `Rakefile` are tracked and always available: `dev_up`,
`seed`, `annotate`, `model_spec`, `web_spec`, `dev_irb`, `pry`.

Any `make` target is local and gitignored, coming from a `Makefile.dev` that the
tracked `Makefile` includes. Where that file is absent, `make` fails on the
include line before running anything. Do not conclude a target is missing from
the library; check for `Makefile.dev` first. There is no official CLI yet for the
import, process, and report flow, so drive the library from a Ruby script. A CLI
is planned; do not add one, and do not document local scripts as if they were the
interface.
