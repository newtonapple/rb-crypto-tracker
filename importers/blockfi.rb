# frozen_string_literal: true

require 'csv'
require 'pdf-reader'
require 'strscan'

module Importers
  # Importer for BlockFi
  class BlockFi
    class PdfPriceExtractor
      attr_reader :monthly_prices, :pdf_file_names

      def initialize(pdf_file_names)
        @pdf_file_names = pdf_file_names
        @monthly_prices = {}
      end

      def extract!
        pdf_file_names.each do |pdf|
          extract_pdf!(pdf)
        end
        monthly_prices
      end

      def extract_pdf!(pdf_file_name)
        pdf = PDF::Reader.new(pdf_file_name)
        text = pdf.pages.map(&:text).join("\n").squeeze("\n")

        scanner = StringScanner.new(text)
        scanner.skip_until(/BlockFi Interest Account Statement/) # only pickup interest pricing, ignore wallet
        scanner.skip_until(/Month Ending\s+/)
        date = Date.parse(scanner.scan_until(/\n/).strip)
        pricing = {}
        @monthly_prices["#{date.year}-#{date.month}"] = pricing
        scanner.skip_until(/Ending Balance/)
        until scanner.eos?
          scanner.skip_until(/1/)
          crypto = scanner.scan_until(/\n/).lstrip.split(/\s+/).first
          price = scanner.scan_until(/\n/).lstrip.split(/\s+/).first
          pricing[crypto] = BigDecimal(price.gsub(/[$,]/, ''))
          return monthly_prices if scanner.peek(10).lstrip.start_with?('Total*')
        end
      end
    end

    TYPE = 'Transaction Type'
    TIME = 'Confirmed At'
    AMOUNT = 'Amount'
    CURRENCY = 'Cryptocurrency'

    DOLLAR_PEGGED_COINS = Set.new(%w[USDC BUSD PAX GUSD]).freeze # NOTE: DAI is not pegged to USD on BlockFi

    attr_reader :account, :fiat_currency, :transactions

    def initialize(account:, monthly_prices: {}, fiat_currency: Currency.by_symbol('USD'))
      @account = account
      @fiat_currency = fiat_currency
      @trade_transactions = {}
      @withdraw_transactions = {}
      @monthly_prices = monthly_prices
      @transactions = []
    end

    def parse_monthly_prices_from_pdfs(pdf_file_names)
      @monthly_prices = PdfPriceExtractor.new(pdf_file_names).extract!
    end

    def parse!(report)
      ## BlockFi Transaction Types
      # Internal Transfer - BIA
      # Internal Transfer - Wallet
      # Interest Payment
      # Crypto Transfer
      # ACH Return
      # ACH Transfer
      # ACH Withdrawal Return
      # Wire Transfer
      # Referral Payment
      # Bonus Payment
      # Trade
      # TLH Trade
      # ACH Trade
      # ACH Trade Return
      # Credit Card
      # Credit Card Rewards
      # Credit Card Trading Rebate
      # Credit Card Referral Bonus
      # Credit Card Stablecoin Boost
      csv = CSV.parse(report, headers: true).sort_by { |r| [r[TIME] || '', r[TYPE]] } # TYPE is used to sort withdrawal before withdrawal fee
      csv.each do |row|
        next unless row[TIME]

        case row[TYPE]
        when /Trade$/
          parse_trade!(row)
        when 'Ach Deposit' # fiat to crypto
          parse_buy!(row)
        when 'Ach Withdrawal' # # crypto to fiat
          parse_sell!(row)
        when 'Cc Rewards Redemption', 'Cc Trading Rebate'
          parse_crypto_transaction!(row, 'refund')
        when 'Interest Payment'
          parse_crypto_transaction!(row, 'interest')
        when 'Bonus Payment'
          parse_crypto_transaction!(row, 'reward')
        when 'Crypto Transfer'
          parse_crypto_transaction!(row, 'transfer_in')
        when 'Withdrawal'
          # "BIA Withdraw" is just a transfer from interest account to wallet
          # The amount of cryptos with have on Blockfi remains the same
          parse_withdraw!(row)
        when 'Withdrawal Fee'
          parse_crypto_withdraw_fee!(row)
          # when 'Wallet Liquidation To Cash' # push liquidation process until next year (2024)
        end
      end
      transactions
    end

    private

    def parse_buy!(row)
      transaction = init_transaction(row)
      amount = BigDecimal(row[AMOUNT])
      transaction.type = 'buy'
      transaction.from_currency = fiat_currency
      transaction.from_amount = amount
      transaction.to_currency = Currency.by_symbol(row[CURRENCY])
      transaction.to_amount = amount
    end

    def parse_sell!(row)
      transaction = init_transaction(row)
      amount = BigDecimal(row[AMOUNT])
      currency = Currency.by_symbol(row[CURRENCY])
      transaction.type = 'sell'
      transaction.from_currency = currency
      transaction.from_amount = amount
      return unless dollar_pegged_coin?(currency)

      transaction.to_currency = fiat_currency
      transaction.to_amount = amount.abs
    end

    def parse_withdraw!(row)
      transaction = parse_crypto_transaction!(row, 'transfer_out')
      completed_at = transaction.completed_at.to_i
      raise "Withdrawal already exist for #{row[CURRENCY]} at #{row[TIME]}" if @withdraw_transactions[completed_at]

      @withdraw_transactions[completed_at] = transaction
    end

    def parse_crypto_transaction!(row, type)
      transaction = init_transaction(row)
      currency = Currency.by_symbol(row[CURRENCY])
      return unless currency&.crypto?

      amount = BigDecimal(row[AMOUNT])
      transaction.from_currency = currency
      transaction.from_amount = amount
      transaction.to_currency = currency
      transaction.to_amount = amount
      transaction.type = type
      infer_market_value_from_monthly_pricing(transaction)
      infer_market_value(transaction)
      transaction
    end

    def parse_crypto_withdraw_fee!(row)
      completed_at = Time.parse(row[TIME]).to_i
      transaction = @withdraw_transactions[completed_at]
      raise "Transaction missing for withdrawal fee #{row[AMOUNT]} #{row[CURRENCY]} at #{row[TIME]}" unless transaction

      currency = Currency.by_symbol(row[CURRENCY])
      amount = BigDecimal(row[AMOUNT])
      transaction.fee_currency = currency
      transaction.fee = amount
      transaction.to_amount = transaction.from_amount = transaction.from_amount + amount # amount is already negative
    end

    # each trade contains 2 rows in the CSV
    # one row for buy and one row for sell
    def parse_trade!(row)
      transaction = init_trade(row)
      transaction.set_amount!(Currency.by_symbol(row[CURRENCY]), BigDecimal(row[AMOUNT]))
      transaction.classify_trade!
      infer_market_value(transaction)
    end

    def infer_market_value(transaction)
      return unless %w[exchange transferred_in].include?(transaction.type)

      if dollar_pegged_coin?(transaction.from_currency)
        transaction.market_value = transaction.from_amount.abs
        transaction.market_value_currency = fiat_currency
      elsif dollar_pegged_coin?(transaction.to_currency)
        transaction.market_value = transaction.to_amount
        transaction.market_value_currency = fiat_currency
      end
    end

    def infer_market_value_from_monthly_pricing(transaction)
      return unless %w[interest reward refund].include?(transaction.type)

      time = transaction.completed_at
      month = "#{time.year}-#{time.month}"
      prices = @monthly_prices[month]
      return unless prices

      price = prices[transaction.to_currency.symbol]
      return unless price

      transaction.market_value_currency = fiat_currency
      transaction.market_value = price * transaction.to_amount
    end

    def init_trade(row)
      completed_at = Time.parse(row[TIME])
      platform_transaction_id = "#{row[TYPE]}:#{completed_at.to_i}"

      transation = @trade_transactions[platform_transaction_id]
      return transation if transation

      transaction = Transaction.new(account:, platform_transaction_id:, completed_at:)
      @trade_transactions[platform_transaction_id] = transaction
      @transactions << transaction
      transaction
    end

    def init_transaction(row)
      completed_at = Time.parse(row[TIME])
      platform_transaction_id = "#{row[TYPE]}:#{completed_at.to_i}:#{row[CURRENCY]}:#{row[AMOUNT]}"
      transaction = Transaction.new(account:, platform_transaction_id:, completed_at:)
      @transactions << transaction
      transaction
    end

    def dollar_pegged_coin?(currency)
      DOLLAR_PEGGED_COINS.include?(currency.symbol)
    end
  end
end
