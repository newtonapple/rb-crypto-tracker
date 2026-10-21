# rb-crypto-tracker

Crypto portfolio tracking and cost-basis accounting in Ruby. Roda + Sequel +
PostgreSQL, built on the
[roda-sequel-stack](https://github.com/jeremyevans/roda-sequel-stack) skeleton
(the upstream instructions are kept in `README.rdoc`).

The web app is still a skeleton. The part that does work is the data pipeline:
import transaction exports from exchanges and custodians, normalize them into a
canonical `transactions` table, process them into cost-basis lots, and print
reports or export TurboTax files.

## Documentation

| Page | Covers |
| --- | --- |
| [docs/workflow.md](docs/workflow.md) | Operating procedure for a tax year: seed, import, process, report, export. Per-platform importer notes, recovery, troubleshooting. |
| [docs/data-model.md](docs/data-model.md) | Schema reference with an entity-relationship diagram: 12 tables, 6 enum types, the two tiers of cost columns, index rationale. |
| [docs/accounting.md](docs/accounting.md) | The accounting engine: `process!` dispatch, lot selection, disposal math, transfer matching, bankruptcy losses. |
| [AGENTS.md](AGENTS.md) | Rules for AI agents working in this repo. |

This README keeps the quick reference: setup, commands, and a summary of each
area. The `docs/` pages go into mechanism and cite source lines.

## Requirements

- Ruby 3.2.2 (see `.ruby-version`)
- PostgreSQL 14 (Homebrew formula `postgresql@14`)
- Bundler, then `bundle install`

## Database setup

Start PostgreSQL with your usual method. On macOS with Homebrew that is
`brew services start postgresql@14`.

```
createuser -s postgres
createuser -U postgres rb_crypto_tracker
createdb -U postgres -O rb_crypto_tracker rb_crypto_tracker_production
createdb -U postgres -O rb_crypto_tracker rb_crypto_tracker_test
createdb -U postgres -O rb_crypto_tracker rb_crypto_tracker_development
```

Connect with `psql -d rb_crypto_tracker_development -U rb_crypto_tracker`, or
`pgcli postgresql://rb_crypto_tracker@localhost/rb_crypto_tracker_development`.

Migrate:

```
rake dev_up     # development
rake test_up    # test
rake prod_up    # production
```

## Environment

Two gitignored files feed the environment. Both are local to your machine.

`.env.rb` is loaded automatically by `db.rb` (via `require_relative '.env'`,
which resolves to `.env.rb`). It sets `RB_CRYPTO_TRACKER_DATABASE_URL` and
`RB_CRYPTO_TRACKER_SESSION_SECRET` per `RACK_ENV`. `RACK_ENV` defaults to
`development`.

`.env` is a plain shell file holding exchange API keys. Nothing in the repo
loads it, so source it yourself (`set -a; source .env; set +a`) before running
anything that calls an exchange API. The keys used are:

| Variable | Used by |
| --- | --- |
| `COINBASEPRO_API_KEY`, `COINBASEPRO_API_SECRET`, `COINBASEPRO_API_PASSPHRASE` | `CoinbaseExchange::Signature.from_env`, used by the Coinbase Pro importer to backfill market values and transfer fees |
| `COINMARKETCAP_API_KEY` | the CoinMarketCap map API, used to regenerate `seed/cryptos.json` |
| `COINBASE_API_KEY`, `COINBASE_API_SECRET` | the `coinbase` gem wallet client, not used by the tracked importers |
| `GEMINI_API_KEY`, `GEMINI_API_SECRET` | reserved, no importer reads them today |

Only the Coinbase Exchange variables are needed to run an import.

## The pipeline

The library normalizes platform exports into a `transactions` table, then derives
cost-basis rows from it. Everything runs against one `Portfolio` row and one
`Account` row per platform. There is no CLI yet; drive the library from a Ruby
script.

```ruby
require_relative 'init'                       # loads models against RACK_ENV

portfolio = Portfolio.find_or_create(name: "<PORTFOLIO NAME>")
account = Account.find_or_create(
  portfolio:,
  platform: Platform.by_name("<PLATFORM NAME>"),
  name: "<ACCOUNT NAME>",
  accounting_method: 'hifo',
  started_on: Date.new(<YYYY>, <MM>)
)

csv = File.read("<export>.csv")
importer = Importers::Coinbase.new(account:)
importer.parse!(csv)
importer.transactions.each_value do |t|
  t.save_changes
rescue Sequel::ValidationFailed => e
  puts e.message                              # duplicate on re-import
end

portfolio.process_transactions!               # transactions -> lots, disposals
```

That is the whole shape. Write a script per import year, point it at the export
files your platforms provide, and run it with `bundle exec ruby <script>.rb`.

Reference data must be seeded before imports, because importers resolve currencies
and platforms from load-time caches:

```
rake seed          # platforms + currencies from seed/*.json
```

Rake tasks:

```
rake                     # all specs
rake model_spec          # spec/model/*_spec.rb
rake web_spec            # spec/web/*_spec.rb
rake dev_up              # migrate the development database
rake dev_irb             # irb with models loaded against development
rake pry                 # bin/console (pry + debug, with Unreloader)
rake annotate            # rewrite the schema comment block at the top of each model
```

Run the web app with `bundle exec falcon` (Falcon is the server in the Gemfile;
`rackup` is not installed). It serves a placeholder index page.

See [docs/workflow.md](docs/workflow.md) for the pipeline stages, per-platform
importer notes, recovery, and troubleshooting.

### Local automation

The tracked repo ships no runner for the pipeline above. For now, automate it with
your own scripts that wrap the importers and models, and a gitignored
`Makefile.dev` of targets that run them. The tracked `Makefile` is only
`include Makefile.dev`, so `make` fails on the include line where that file is
absent. An official CLI is planned for the import, process, report, and export
flow; until then the Ruby API is the interface.

## Importers

Each importer is a plain class under `importers/` in the `Importers` module.
They share a shape: `new(account:)`, `parse!(csv_string)`, then read
`#transactions`. They build unsaved `Transaction` objects and the caller saves
them.

| Importer | Source |
| --- | --- |
| `Importers::BlockFi` | BlockFi trades/transactions CSV, plus monthly statement PDFs for interest pricing |
| `Importers::Coinbase` | Coinbase raw transactions tax CSV from the tax documents page |
| `Importers::CoinbasePro` | Coinbase Pro account CSV; backfills market values and transfer fees from the Coinbase Exchange API |
| `Importers::Gemini` | Gemini transaction history CSV |
| `Importers::GeminiEarn` | Gemini Earn/Grow CSV, shares `Gemini::Row` with `Gemini` |
| `Importers::Voyager` | Voyager tax CSV |
| `Importers::VoyagerCustom` | Hand-assembled Voyager CSV, including bankruptcy liquidation rows |

Importers are parsers, not writers. They never touch the database; they return
`Transaction` objects keyed by a platform transaction id.

See [docs/workflow.md](docs/workflow.md) for the header constants each importer
expects and the extra API backfill steps that BlockFi and Coinbase Pro need.

## Accounting model

`Transaction#process!` turns raw transactions into accounting records:

- `buy`, `interest`, `reward`, `refund` create an `Acquisition`, which creates an
  `Asset` lot in an `after_create` hook.
- `sell` consumes lots and creates `Disposal` rows.
- `exchange` does both.
- `transfer_out` / `transfer_in` pair up into a `Transfer`, which moves lots
  between accounts as `TransferredAsset` rows and re-creates them as `Asset`
  rows on the receiving account.
- `loss_bankruptcy_liquidation` disposes everything in the account and records
  any in-kind crypto returned.

Lot selection goes through `Asset.disposal_lots`, which dispatches on
`Account#accounting_method`: `fifo`, `lifo`, or `hifo`. Set the method per
account to match what the platform reports. HIFO tie-breaks with LIFO, which is
what BlockFi does. `spec` is defined in the enum but not implemented.

Transfers are matched by currency, amount, and a +/- 3 day window
(`Transaction::MAX_TRANSFER_DELTA_SECS`). A transfer with no unique match raises,
which is the most common reason a processing run fails.

See [docs/accounting.md](docs/accounting.md) for the dispatch table, the fee
handling that differs between `sell` and `exchange`, partial-lot splits, and the
sequence diagram for a single sale.

## Tax export

`Disposal` extends `Txf::Form8949` (`lib/txf.rb`), which renders the TurboTax TXF
format for Form 8949. Call `Disposal.txf(disposals:, name:, date:, status_1099b:)`
to get the file contents as a string. The `status_1099b:` argument picks the Form
8949 box per account, depending on whether the platform filed a 1099-B:
`:reported` maps to box A short-term and D long-term, `:unreported` to B and E,
`:none` to C and F (`lib/txf.rb:30-36`).

Grouping disposals by account and year, and writing one file per platform, is the
caller's job.

See [docs/accounting.md](docs/accounting.md) for how `capital_gains_treatment`
and the two cost tiers feed the export.

## Layout

```
.
├── apis/
│   ├── coinbase_exchange/
│   │   ├── signature.rb            CB-ACCESS-* HMAC signing (Signature.from_env)
│   │   ├── request.rb              Faraday middleware that applies the signature
│   │   └── async_connection.rb     Faraday + async-http connection builder
│   ├── coin_market_cap.rb          historical price quotes
│   └── coinbase_exchange.rb        module + requires
├── app.rb                          Roda app: plugins, CSP, CSRF, sessions, error pages
├── assets/css/app.scss
├── bin/
│   ├── console                     pry console, RACK_ENV=development
│   ├── db-backup.sh                pg_dump wrapper
│   └── db-restore.sh               dropdb + createdb + psql (destructive)
├── config.ru                       rack/unreloader bootstrap, optional refrigerator
├── db.rb                           Sequel connection; loads .env.rb
├── importers/                      one class per platform, all under module Importers
├── importers.rb                    Unreloader manifest for importers/
├── init.rb                         Unreloader setup for command-line scripts
├── lib/
│   ├── table_formatter.rb          render_table / print_table over tty-table
│   └── txf.rb                      Txf::Form8949 TurboTax writer
├── migrate/                        Sequel migrations, 001_portfolios .. 012_transferred_assets
├── models/                         Sequel models, each headed by a `rake annotate` schema comment
├── models.rb                       Sequel plugin setup + Unreloader manifest
├── public/                         static files (empty)
├── routes/prefix1.rb               scaffold hash-route branch, unused
├── seed/
│   ├── cryptos.json                ~5000 currencies from the CoinMarketCap map API
│   └── fiats.json                  USD only
├── seed.rb                         `rake seed`: platforms + currencies
├── spec/
│   ├── minitest_helper.rb          transactional rollback around every test
│   ├── model/
│   └── web/
├── views/                          ERB layout + placeholder index
├── docs/                           data-model.md, workflow.md, accounting.md
├── .env / .env.rb                  gitignored: API keys, database URL, session secret
├── .dev/                           gitignored: local working data, not part of the library
├── .rubocop.yml
├── .ruby-version                   3.2.2
├── Gemfile
├── Makefile                        tracked; includes gitignored Makefile.dev
└── README.rdoc                     upstream roda-sequel-stack docs
```

`Makefile` is tracked and contains only `include Makefile.dev`. That file is
gitignored, so `make` fails on the include line until you write your own.

`.dev/` is gitignored and is not part of the library. It is where a checkout keeps
its own exports, scripts, and database dumps. Everything the library needs is in
the tracked directories above.

## Development notes

- `rubocop` is configured in `.rubocop.yml` (155-char lines, 50-line methods,
  sequel + performance cops). The repo is not clean today; run it on files you
  touch rather than the tree.
- Models are annotated by `rake annotate`. The comment block at the top of each
  model is generated; regenerate it after a migration instead of editing it.
- `Currency` and `Platform` use Sequel's `static_cache` and build `BY_SYMBOL` /
  `BY_NAME` hashes at load time. They are read-only at runtime. `seed.rb`
  reopens them to allow modification while seeding.
- `Asset`, `Disposal`, `Transfer`, `TransferredAsset`, `Acquisition`, and
  `Transaction` each define `TABLE_HEADERS`, `TABLE_ALIGNMENTS`, and `table_row`,
  and extend `TableFormatter`, which is what every report prints through.
- Amounts are `BigDecimal` end to end. Format with `.to_s('F')` to avoid
  scientific notation in output.
