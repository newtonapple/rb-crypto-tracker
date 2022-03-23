# frozen_string_literal: true

# Table: portfolios
# Columns:
#  id         | integer                     | PRIMARY KEY GENERATED BY DEFAULT AS IDENTITY
#  name       | character varying(255)      | NOT NULL
#  created_at | timestamp without time zone | NOT NULL
#  updated_at | timestamp without time zone | NOT NULL
# Indexes:
#  portfolios_pkey             | PRIMARY KEY btree (id)
#  portfolios_created_at_index | btree (created_at)
#  portfolios_name_index       | btree (name)
# Referenced By:
#  accounts     | accounts_portfolio_id_fkey     | (portfolio_id) REFERENCES portfolios(id)
#  assets       | assets_portfolio_id_fkey       | (portfolio_id) REFERENCES portfolios(id)
#  disposals    | disposals_portfolio_id_fkey    | (portfolio_id) REFERENCES portfolios(id)
#  transactions | transactions_portfolio_id_fkey | (portfolio_id) REFERENCES portfolios(id)

class Portfolio < Sequel::Model
  many_to_many :platforms, join_table: :accounts
  one_to_many :accounts
  one_to_many :assets
  one_to_many :disposals

  one_to_many :transactions
  one_to_many :unprocessed_transactions, class: :Transaction do |ds|
    ds.eager(:account).where(processed: false).order(:completed_at)
  end

  def reset_transactions!
    accounts.each(&:reset_transactions!)
  end

  def delete_transactions!
    accounts.each(&:delete_transactions!)
  end

  def process_transactions!
    unprocessed_transactions.each(&:process!)
  end
end
