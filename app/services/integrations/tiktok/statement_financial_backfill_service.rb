require "digest"
require "json"

module Integrations
  module Tiktok
    # Statement-first historical financial sync. It only updates orders that
    # already exist locally and leaves the old order-scoped backfill intact so
    # the two strategies can be compared during rollout.
    class StatementFinancialBackfillService
      ACTION = "tiktok_statement_financial_backfill".freeze
      STATEMENT_ACTION = "tiktok_statement_financial_statement".freeze
      API_DATA_START = Date.new(2023, 7, 1).freeze
      DEFAULT_PAGE_SIZE = 100
      MAX_ERROR_SAMPLES = 20

      Result = Struct.new(:outcome, :error_message, :metadata, keyword_init: true) do
        def success? = outcome == :success
        def error? = outcome == :error
        def skipped? = outcome == :skipped
        def rate_limited? = outcome == :rate_limited
        def pending? = outcome == :pending
      end

      def self.call(
        channel_credential,
        date_from:,
        date_to:,
        force: false,
        run_id: nil,
        max_statements: nil
      )
        new(
          channel_credential,
          date_from: date_from,
          date_to: date_to,
          force: force,
          run_id: run_id,
          max_statements: max_statements
        ).call
      end

      def self.claim_continuation!(channel_credential:, run_id:, continuation_run_at:)
        log = IntegrationSyncLog
          .where(tenant: channel_credential.tenant, action: ACTION, status: %w[pending error])
          .order(created_at: :desc)
          .find do |candidate|
            metadata = candidate.metadata.to_h
            metadata["channel_credential_id"].to_s == channel_credential.id.to_s &&
              metadata["run_id"].to_s == run_id.to_s
          end
        return false unless log

        scheduled = false
        log.with_lock do
          metadata = log.metadata.to_h
          existing = [ metadata["continuation_run_at"] ].filter_map do |value|
            Time.zone.parse(value.to_s) if value.present?
          rescue ArgumentError, TypeError
            nil
          end
          unless existing.any? { |time| time > Time.current }
            metadata["continuation_scheduled_at"] = Time.current
            metadata["continuation_run_at"] = continuation_run_at
            metadata["continuation_count"] = metadata.fetch("continuation_count", 0).to_i + 1
            log.update!(status: "pending", finished_at: nil, metadata: metadata)
            scheduled = true
          end
        end
        scheduled
      end

      def initialize(channel_credential, date_from:, date_to:, force:, run_id:, max_statements:)
        @channel_credential = channel_credential
        @tenant = channel_credential.tenant
        @date_from = parse_date(date_from)
        @date_to = parse_date(date_to)
        @force = ActiveModel::Type::Boolean.new.cast(force)
        @run_id = run_id.to_s.presence
        @max_statements = max_statements.nil? ? nil : Integer(max_statements)
        @adapter = Integrations::TiktokAdapter.new(channel_credential.credentials)
        @lock = FinancialSyncLock.new(channel_credential)
        initialize_counters
      end

      def call
        validate_dates!
        return result(:skipped, "intervalo anterior ao limite suportado pela API") if date_to < API_DATA_START

        @channel = tenant.channels.find_by(platform: "tiktok")
        return result(:skipped, "canal tiktok não encontrado") unless channel

        unless lock.acquire
          raise FinancialSyncLock::LockBusyError,
            "backfill financeiro por statement TikTok já está em execução"
        end

        @lock_acquired = true
        resume_or_start_run_log
        fetch_and_process_statements
        outcome = if error_count.positive?
          :error
        elsif max_reached?
          :pending
        else
          :success
        end
        finish_run_log(outcome.to_s)
        result(outcome, log.error_message)
      rescue Integrations::AuthenticationError => e
        finish_run_log("error", e.message)
        channel_credential.update!(status: "error")
        result(:error, e.message)
      rescue Integrations::RateLimitError => e
        @rate_limit_count += 1
        persist_checkpoint(error_message: "rate_limited: #{e.message}") if log
        raise
      rescue FinancialSyncLock::LockLostError
        finish_run_log("error", "lock perdido")
        raise
      rescue ArgumentError => e
        finish_run_log("error", e.message)
        result(:error, e.message)
      ensure
        lock.release if lock_acquired
      end

      private

      attr_reader :channel_credential, :tenant, :date_from, :date_to, :adapter,
        :lock, :channel, :log, :run_id, :error_samples

      def initialize_counters
        @processed_statements = 0
        @processed_transactions = 0
        @matched_orders = 0
        @synced_orders = 0
        @missing_orders = 0
        @skipped_orders = 0
        @error_count = 0
        @rate_limit_count = 0
        @continuation_count = 0
        @statement_page_token = nil
        @current_statement_time = nil
        @current_statement_id = nil
        @current_page_token = nil
        @error_samples = []
        @lock_acquired = false
        @max_reached = false
      end

      def parse_date(value)
        return value.to_date if value.respond_to?(:to_date)

        Date.iso8601(value.to_s)
      rescue ArgumentError, TypeError
        raise ArgumentError, "data TikTok inválida: #{value.inspect}"
      end

      def validate_dates!
        raise ArgumentError, "date_from não pode ser posterior a date_to" if date_from > date_to
        raise ArgumentError, "max_statements deve ser positivo" if max_statements && max_statements <= 0
      end

      def api_from
        start_date = [ date_from, API_DATA_START ].max
        Time.utc(start_date.year, start_date.month, start_date.day).to_i
      end

      # `date_to` is inclusive at the task boundary; TikTok's `lt` bound is
      # exclusive, so the next UTC day is sent to the API.
      def api_to
        end_date = date_to + 1.day
        Time.utc(end_date.year, end_date.month, end_date.day).to_i
      end

      def resume_or_start_run_log
        @run_id ||= SecureRandom.uuid
        @log = resumable_run_log
        if log
          restore_checkpoint
        else
          @log = IntegrationSyncLog.create!(run_log_attributes)
        end
      end

      def resumable_run_log
        IntegrationSyncLog
          .where(tenant: tenant, action: ACTION, status: %w[pending error])
          .order(created_at: :desc)
          .find do |candidate|
            candidate.metadata.to_h["channel_credential_id"].to_s == channel_credential.id.to_s &&
              candidate.metadata.to_h["run_id"].to_s == run_id.to_s
          end
      end

      def restore_checkpoint
        metadata = log.metadata.to_h
        @processed_statements = metadata["processed_statements"].to_i
        @processed_transactions = metadata["processed_transactions"].to_i
        @matched_orders = metadata["matched_orders"].to_i
        @synced_orders = metadata["synced_orders"].to_i
        @missing_orders = metadata["missing_orders"].to_i
        @skipped_orders = metadata["skipped_orders"].to_i
        @error_count = metadata["error_count"].to_i
        @rate_limit_count = metadata["rate_limit_count"].to_i
        @continuation_count = metadata["continuation_count"].to_i
        @statement_page_token = metadata["statement_page_token"].presence
        @current_statement_time = metadata["current_statement_time"]
        @current_statement_id = metadata["current_statement_id"]
        @current_page_token = metadata["current_page_token"]
        @error_samples = Array(metadata["error_samples"]).first(MAX_ERROR_SAMPLES)
      end

      def fetch_and_process_statements
        return fetch_statement_pages_with_checkpoint if adapter.is_a?(Integrations::TiktokAdapter)

        payload = adapter.fetch_financial_statements(
          statement_time_ge: api_from,
          statement_time_lt: api_to,
          page_size: DEFAULT_PAGE_SIZE,
          page_token: statement_page_token
        )
        statements = payload.is_a?(Hash) ? payload.dig("data", "statements") : payload
        statements = Array(statements)

        statements.each do |statement|
          if max_statements && processed_statements >= max_statements
            @max_reached = true
            break
          end

          process_statement(statement)
          @processed_statements += 1
          @statement_page_token = nil
          persist_checkpoint
        end

        # PaginatedPayload exposes the raw pages without changing the remote
        # objects. If a limit stopped in the middle of a page, the statement
        # id checkpoint makes the next pass skip already completed statements.
        if payload.respond_to?(:raw_pages)
          @statement_page_token = payload.raw_pages.last&.dig("data", "next_page_token").presence
        end
        persist_checkpoint
      end

      def fetch_statement_pages_with_checkpoint
        cursor = statement_page_token

        loop do
          payload = adapter.fetch_financial_statements_page(
            statement_time_ge: api_from,
            statement_time_lt: api_to,
            page_size: DEFAULT_PAGE_SIZE,
            page_token: cursor
          )
          statements = Array(payload.dig("data", "statements"))
          break if statements.empty?

          statements.each do |statement|
            if max_statements && processed_statements >= max_statements
              @max_reached = true
              break
            end

            process_statement(statement)
            @processed_statements += 1
            @current_page_token = cursor
            persist_checkpoint
          end

          next_cursor = payload.dig("data", "next_page_token").presence
          @statement_page_token = if max_statements && processed_statements >= max_statements
            @max_reached = true
            cursor
          else
            next_cursor
          end
          persist_checkpoint
          break if @statement_page_token.blank? || (max_statements && processed_statements >= max_statements)

          cursor = @statement_page_token
        end
      end

      def process_statement(statement)
        unless statement.is_a?(Hash) && statement["id"].present?
          record_error(nil, "statement sem id")
          return
        end

        statement_id = statement["id"].to_s
        @current_statement_id = statement_id
        @current_statement_time = statement["statement_time"]
        checksum = Digest::SHA256.hexdigest(JSON.generate(statement))
        statement_log = find_statement_log(statement_id)

        if skip_statement?(statement_log, checksum)
          @skipped_statement_count = @skipped_statement_count.to_i + 1
          return
        end

        mark_statement_started(statement_log, statement, checksum)
        counters_before = counters_snapshot
        transactions, raw_transaction_pages = fetch_statement_transactions(statement_log, statement_id)
        @processed_transactions += transactions.size
        process_transactions(statement, transactions)
        finish_statement_log(
          statement_log,
          status: "success",
          checksum: checksum,
          transaction_count: transactions.size,
          raw_transactions: raw_transaction_pages.flat_map { |page| Array(page.dig("data", "transactions")) },
          counts: counters_delta(counters_before)
        )
        @current_page_token = nil
      rescue Integrations::AuthenticationError, Integrations::RateLimitError, Faraday::Error
        raise
      rescue Integrations::ApiError => e
        raise if temporary_api_error?(e)

        record_error(statement_id, e.message)
        finish_statement_log(statement_log, status: "error", checksum: checksum, transaction_count: 0,
          error_message: e.message, counts: counters_delta(counters_before || counters_snapshot)) if statement_log
      rescue => e
        record_error(statement_id, e.message)
        finish_statement_log(statement_log, status: "error", checksum: checksum, transaction_count: 0,
          error_message: e.message, counts: counters_delta(counters_before || counters_snapshot)) if statement_log
      end

      def process_transactions(statement, transactions)
        grouped = Hash.new { |hash, key| hash[key] = [] }
        non_order_transactions = {}
        invalid_transactions = []
        seen = {}

        transactions.each do |raw_transaction|
          next unless raw_transaction.is_a?(Hash)

          transaction_key = raw_transaction["id"].presence || Digest::SHA256.hexdigest(JSON.generate(raw_transaction))
          next if seen[transaction_key]

          seen[transaction_key] = true
          parsed = FinancialTransactionParser.call(raw_transaction, origin: :statement)
          unless parsed[:processable]
            non_order_transactions[parsed[:order_id].to_s] = parsed if parsed[:order_id].present?
            next
          end

          grouped[parsed[:order_id].to_s] << parsed
        rescue FinancialTransactionParser::InvalidTransactionError => e
          invalid_transactions << [ raw_transaction, e.message ]
        end

        grouped.each do |external_id, parsed_transactions|
          sync_order_from_statement(statement, external_id, parsed_transactions)
        end

        # Defer malformed-transaction fallback until valid statement rows have
        # been grouped. This avoids an unnecessary individual API request when
        # another complete row for the same order is sufficient to sync it.
        invalid_transactions.each do |raw_transaction, message|
          external_id = raw_transaction.is_a?(Hash) ? raw_transaction["order_id"].presence : nil
          next if external_id.present? && grouped.key?(external_id.to_s)

          fallback_for_transaction(raw_transaction, message)
        end

        # An adjustment may reference an order but contain no complete sale
        # components. Only use the individual endpoint when the statement did
        # not also provide a complete order transaction for that order.
        non_order_transactions.each do |external_id, parsed|
          next if grouped.key?(external_id)

          order = channel.orders.find_by(external_id: external_id)
          fallback_order(order, "#{parsed[:transaction_type]} sem transação de pedido completa") if order
        end
      end

      def fetch_statement_transactions(statement_log, statement_id)
        return fetch_statement_transactions_with_checkpoint(statement_log, statement_id) if adapter.is_a?(Integrations::TiktokAdapter)

        payload = adapter.fetch_statement_transactions(
          statement_id: statement_id,
          page_size: DEFAULT_PAGE_SIZE,
          page_token: statement_log.metadata.to_h["current_page_token"].presence
        )
        transactions = payload.is_a?(Hash) ? payload.dig("data", "transactions") : payload
        raw_pages = if payload.respond_to?(:raw_pages)
          payload.raw_pages
        else
          [ { "data" => { "transactions" => Array(transactions) } } ]
        end
        [ Array(transactions), raw_pages ]
      end

      def fetch_statement_transactions_with_checkpoint(statement_log, statement_id)
        cursor = statement_log.metadata.to_h["current_page_token"].presence
        transactions = []
        raw_pages = []

        loop do
          response = adapter.fetch_statement_transactions_page(
            statement_id: statement_id,
            page_size: DEFAULT_PAGE_SIZE,
            page_token: cursor
          )
          raw_pages << response
          page_transactions = Array(response.dig("data", "transactions"))
          transactions.concat(page_transactions)

          cursor = response.dig("data", "next_page_token").presence
          @current_page_token = cursor
          statement_log.metadata = statement_log.metadata.to_h.merge(
            "current_page_token" => cursor,
            "transaction_count" => transactions.size
          )
          statement_log.save!
          persist_checkpoint
          # Statement PAID sem nenhuma transação (ou fim real da paginação)
          # chega como página vazia — parar aqui é o que garante o avanço.
          # Sem essa guarda, uma TikTok que devolve next_page_token não-nulo
          # numa página vazia prende o loop pra sempre no mesmo cursor: o
          # statement nunca chega em finish_statement_log, processed_at
          # nunca é preenchido, e o job — ao reencontrar o mesmo checkpoint
          # na próxima execução — repete o mesmo ciclo indefinidamente.
          break if page_transactions.empty? || cursor.blank?
        end

        [ transactions, raw_pages ]
      end

      def sync_order_from_statement(statement, external_id, parsed_transactions)
        order = channel.orders.find_by(external_id: external_id)
        unless order
          @missing_orders += 1
          return
        end

        @matched_orders += 1
        if order.financial_synced_at.present? && !force
          @skipped_orders += 1
          return
        end

        normalized = FinancialTransactionParser.aggregate(
          parsed_transactions,
          raw_payload: {
            "source" => "statement",
            "statement" => statement,
            "transactions" => parsed_transactions.map { |row| row[:financial_breakdown] }
          }
        )
        OrderFinancialSyncService.persist!(order: order, normalized: normalized)
        clear_pending_tracking(order)
        @synced_orders += 1
      rescue FinancialTransactionParser::InvalidTransactionError, ActiveRecord::RecordInvalid => e
        fallback_order(order, e.message) if order
      rescue Integrations::ApiError => e
        fallback_order(order, e.message) if order
      end

      def fallback_for_transaction(raw_transaction, message)
        external_id = raw_transaction.is_a?(Hash) ? raw_transaction["order_id"].presence : nil
        order = external_id && channel.orders.find_by(external_id: external_id.to_s)
        fallback_order(order, message) if order
      end

      def fallback_order(order, reason)
        return unless order
        return if order.financial_synced_at.present? && !force

        OrderFinancialSyncService.call(
          order: order,
          channel_credential: channel_credential,
          adapter: adapter,
          force: force
        )
        @synced_orders += 1
      rescue Integrations::Tiktok::OrderFinancialSyncService::PendingStatementError => e
        record_error(order.external_id, e.message)
      rescue => e
        record_error(order.external_id, "fallback: #{e.message}")
      end

      def find_statement_log(statement_id)
        scope = IntegrationSyncLog.where(tenant: tenant, action: STATEMENT_ACTION)
        if integration_sync_log_has?(:channel_credential_id) && integration_sync_log_has?(:statement_id)
          scope.find_by(channel_credential_id: channel_credential.id, statement_id: statement_id) ||
            IntegrationSyncLog.new(tenant: tenant, action: STATEMENT_ACTION)
        else
          scope.order(created_at: :desc).find do |candidate|
            candidate.metadata.to_h["channel_credential_id"].to_s == channel_credential.id.to_s &&
              candidate.metadata.to_h["statement_id"].to_s == statement_id.to_s
          end || IntegrationSyncLog.new(tenant: tenant, action: STATEMENT_ACTION)
        end
      end

      def skip_statement?(statement_log, checksum)
        return false unless statement_log.persisted?
        return false if force
        return false unless statement_log.status == "success"
        stored_checksum = column_value(statement_log, :payload_checksum)
        return false if stored_checksum.present? && stored_checksum != checksum

        column_value(statement_log, :missing_order_count).to_i.zero? &&
          column_value(statement_log, :error_count).to_i.zero? &&
          statement_log.metadata.to_h["missing_order_count"].to_i.zero?
      end

      def mark_statement_started(statement_log, statement, checksum)
        current_page_token = statement_log.metadata.to_h["current_page_token"].presence
        assign_if_column(statement_log, :tenant, tenant)
        assign_if_column(statement_log, :action, STATEMENT_ACTION)
        assign_if_column(statement_log, :direction, "inbound")
        assign_if_column(statement_log, :status, "pending")
        assign_if_column(statement_log, :channel_credential_id, channel_credential.id)
        assign_if_column(statement_log, :statement_id, statement["id"].to_s)
        assign_if_column(statement_log, :statement_time, timestamp_for(statement["statement_time"]))
        assign_if_column(statement_log, :payment_status, statement["payment_status"])
        assign_if_column(statement_log, :payload_checksum, checksum)
        assign_if_column(statement_log, :started_at, Time.current)
        assign_if_column(statement_log, :response_payload, statement)
        statement_log.metadata = statement_log.metadata.to_h.merge(
          "channel_credential_id" => channel_credential.id,
          "statement_id" => statement["id"].to_s,
          "statement_time" => statement["statement_time"],
          "payment_status" => statement["payment_status"],
          "payload_checksum" => checksum,
          "current_page_token" => current_page_token
        )
        statement_log.save!
      end

      def finish_statement_log(statement_log, status:, checksum:, transaction_count:, counts:, error_message: nil,
        raw_transactions: nil)
        statement_log.assign_attributes(metadata: statement_log.metadata.to_h.merge(
          "transaction_count" => transaction_count,
          "matched_order_count" => counts[:matched_orders],
          "synced_order_count" => counts[:synced_orders],
          "missing_order_count" => counts[:missing_orders],
          "error_count" => counts[:error_count]
        ))
        assign_if_column(statement_log, :status, status)
        assign_if_column(statement_log, :payload_checksum, checksum)
        assign_if_column(statement_log, :transaction_count, transaction_count)
        assign_if_column(statement_log, :matched_order_count, counts[:matched_orders])
        assign_if_column(statement_log, :synced_order_count, counts[:synced_orders])
        assign_if_column(statement_log, :missing_order_count, counts[:missing_orders])
        assign_if_column(statement_log, :error_count, counts[:error_count])
        assign_if_column(statement_log, :processed_at, Time.current)
        assign_if_column(statement_log, :finished_at, Time.current)
        assign_if_column(statement_log, :error_message, error_message)
        if raw_transactions && statement_log.class.column_names.include?("response_payload")
          statement_log.response_payload = statement_log.response_payload.to_h.merge("transactions" => raw_transactions)
        end
        statement_log.save!
      end

      def run_log_attributes
        {
          tenant: tenant,
          direction: "inbound",
          action: ACTION,
          status: "pending",
          started_at: Time.current,
          metadata: metadata_snapshot
        }
      end

      def persist_checkpoint(error_message: nil)
        return unless log

        log.update!(
          status: "pending",
          finished_at: nil,
          error_message: error_message,
          metadata: (log.metadata || {}).merge(metadata_snapshot)
        )
      end

      def finish_run_log(status, error_message = nil)
        return unless log

        finished_at = status == "pending" ? nil : Time.current
        log.update!(
          status: status,
          finished_at: finished_at,
          error_message: error_message,
          metadata: (log.metadata || {}).merge(metadata_snapshot)
        )
      end

      def metadata_snapshot
        {
          "channel_credential_id" => channel_credential.id,
          "run_id" => run_id,
          "date_from" => date_from.iso8601,
          "date_to" => date_to.iso8601,
          "current_statement_time" => current_statement_time,
          "current_statement_id" => current_statement_id,
          "current_page_token" => current_page_token,
          "statement_page_token" => statement_page_token,
          "processed_statements" => processed_statements,
          "processed_transactions" => processed_transactions,
          "matched_orders" => matched_orders,
          "synced_orders" => synced_orders,
          "missing_orders" => missing_orders,
          "skipped_orders" => skipped_orders,
          "error_count" => error_count,
          "rate_limit_count" => rate_limit_count,
          "continuation_count" => continuation_count,
          "error_samples" => error_samples
        }
      end

      def record_error(identifier, message)
        @error_count += 1
        return if error_samples.size >= MAX_ERROR_SAMPLES

        error_samples << { identifier: identifier, message: message }
      end

      def temporary_api_error?(error)
        error.message.to_s.match?(/HTTP\s+5\d\d|resposta inesperada/i)
      end

      def timestamp_for(value)
        return if value.blank?

        Time.zone.at(value.to_i)
      end

      def clear_pending_tracking(order)
        return unless Order.column_names.include?("financial_pending_reason")

        order.update_columns(financial_pending_reason: nil, financial_next_attempt_at: nil)
      end

      def assign_if_column(record, attribute, value)
        return unless record.class.column_names.include?(attribute.to_s)

        record.public_send("#{attribute}=", value)
      end

      def column_value(record, attribute)
        return nil unless record.class.column_names.include?(attribute.to_s)

        record.public_send(attribute)
      end

      def counters_snapshot
        {
          matched_orders: matched_orders,
          synced_orders: synced_orders,
          missing_orders: missing_orders,
          error_count: error_count
        }
      end

      def counters_delta(before)
        now = counters_snapshot
        now.keys.index_with { |key| now[key] - before[key] }
      end

      def integration_sync_log_has?(attribute)
        IntegrationSyncLog.column_names.include?(attribute.to_s)
      end

      def processed_statements = @processed_statements
      def processed_transactions = @processed_transactions
      def matched_orders = @matched_orders
      def synced_orders = @synced_orders
      def missing_orders = @missing_orders
      def skipped_orders = @skipped_orders
      def error_count = @error_count
      def rate_limit_count = @rate_limit_count
      def continuation_count = @continuation_count
      def current_statement_time = @current_statement_time
      def current_statement_id = @current_statement_id
      def current_page_token = @current_page_token
      def statement_page_token = @statement_page_token
      def max_statements = @max_statements
      def max_reached? = @max_reached
      def force = @force
      def lock_acquired = @lock_acquired
      def result(outcome, error_message = nil)
        Result.new(outcome: outcome, error_message: error_message, metadata: metadata_snapshot)
      end
    end
  end
end
