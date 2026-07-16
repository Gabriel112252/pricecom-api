module Integrations
  module Yampi
    # Pulls abandoned carts from GET /checkout/carts — same
    # backfill/incremental cursor scheme as OrdersPollingService, but with
    # its own cursor column (carts_sync_cursor_at) and its own lock scope,
    # since both pollings can run concurrently for the same credential. The
    # RateLimiter is shared per store alias, so carts and orders polling
    # together still respect the account-wide Yampi budget.
    class CartsPollingService
      BACKFILL_DAYS = 90
      INCREMENTAL_OVERLAP = 10.minutes
      INCREMENTAL_CREATED_AT_LOOKBACK_DAYS = 3
      LIMIT = Integrations::YampiAdapter::CARTS_LIMIT

      PollingEvent = Struct.new(:tenant, :payload, :event_type, :integration, keyword_init: true)

      Result = Struct.new(:outcome, :error_message, :retry_after, :metadata, keyword_init: true) do
        def success? = outcome == :success
        def error? = outcome == :error
        def skipped? = outcome == :skipped
        def rate_limited? = outcome == :rate_limited
      end

      def self.call(channel_credential, trigger: "scheduled")
        new(channel_credential, trigger: trigger).call
      end

      def initialize(channel_credential, trigger: "scheduled")
        @channel_credential = channel_credential
        @tenant = channel_credential.tenant
        @trigger = trigger
        @integration = tenant.integrations.active.find_by(provider: "yampi")
        @adapter = Integrations::YampiAdapter.new(channel_credential.credentials)
        @rate_limiter = RateLimiter.new(channel_credential.credentials.to_h.with_indifferent_access[:alias])
        @lock = PollingLock.new(channel_credential, scope: "carts_polling")
        @started_at = Time.current
        @cursor_to = @started_at.utc
        @previous_cursor_at = channel_credential.carts_sync_cursor_at&.utc
        @sync_mode = previous_cursor_at.present? ? "incremental" : "backfill"
        @cursor_from = sync_mode == "incremental" ? incremental_cursor_from : cursor_to - BACKFILL_DAYS.days
        @max_seen_cursor_at = nil
        @seen_external_ids = Set.new
        initialize_counters
      end

      def call
        @log = start_log

        unless channel_credential.polling_enabled?
          finish_log(status: "skipped", error_message: "polling desabilitado")
          return result(:skipped, "polling desabilitado")
        end

        unless lock.acquire
          @lock_acquired = false
          finish_log(status: "skipped", error_message: "polling de carrinhos já em execução")
          return result(:skipped, "polling de carrinhos já em execução")
        end

        @lock_acquired = true
        Channel.ensure_for!(tenant, "yampi")
        fetch_and_process_pages

        if error_count.positive?
          finish_log(status: "error", error_message: item_errors.first&.fetch(:message, nil))
          return result(:error, item_errors.first&.fetch(:message, nil))
        end

        @new_cursor_at = next_cursor_at
        channel_credential.update!(carts_sync_cursor_at: @new_cursor_at)
        finish_log(status: "success")
        result(:success, nil)
      rescue Integrations::AuthenticationError => e
        channel_credential.update!(status: "error")
        finish_log(status: "error", error_message: e.message)
        result(:error, e.message)
      rescue Integrations::RateLimitError => e
        @rate_limited = true
        @retry_after = e.retry_after || rate_limiter.reserve_retry_after
        finish_log(status: "error", error_message: "rate_limited: #{e.message}")
        result(:rate_limited, e.message, retry_after: retry_after)
      rescue Integrations::ApiError => e
        finish_log(status: "error", error_message: e.message)
        result(:error, e.message)
      rescue => e
        finish_log(status: "error", error_message: e.message)
        result(:error, e.message)
      ensure
        lock.release if lock_acquired
      end

      private

      attr_reader :channel_credential, :tenant, :trigger, :integration, :adapter, :rate_limiter, :lock,
        :started_at, :cursor_to, :previous_cursor_at, :sync_mode, :cursor_from, :seen_external_ids,
        :log, :retry_after

      def incremental_cursor_from
        [ previous_cursor_at - INCREMENTAL_OVERLAP, cursor_to - INCREMENTAL_CREATED_AT_LOOKBACK_DAYS.days ].min
      end

      def initialize_counters
        @pages_fetched = 0
        @api_requests_count = 0
        @api_records_received = 0
        @records_inside_cursor_window = 0
        @outside_cursor_window_count = 0
        @created_count = 0
        @updated_count = 0
        @ignored_count = 0
        @error_count = 0
        @rate_limited = false
        @retry_after = nil
        @lock_acquired = nil
        @new_cursor_at = nil
        @last_request_at = nil
        @item_errors = []
        @ignored_examples = []
        @processed_examples = []
      end

      def fetch_and_process_pages
        page = 1

        loop do
          wait_for_one_request_per_second
          reserve_internal_rate_limit!

          response = adapter.fetch_carts_page(page: page, date_filter: date_filter, limit: LIMIT, skip_cache: true)
          @api_requests_count += 1
          rate_limiter.observe(response.headers)
          handle_api_status!(response)

          @pages_fetched += 1
          process_page(response.data)
          lock.renew

          raise_provider_reserve_if_needed!

          pagination = response.pagination
          total_pages = pagination["total_pages"].to_i
          break if response.data.empty? || total_pages <= page

          page += 1
        end
      end

      def reserve_internal_rate_limit!
        reservation = rate_limiter.reserve!
        return if reservation.allowed

        raise Integrations::RateLimitError.new(
          "orçamento interno Yampi esgotado",
          retry_after: rate_limiter.retry_after_for(reservation)
        )
      end

      def handle_api_status!(response)
        case response.status
        when 200..299
          true
        when 401, 403
          raise Integrations::AuthenticationError,
            "Integrations::YampiAdapter: credenciais rejeitadas (HTTP #{response.status})"
        when 429
          retry_after = response.retry_after || rate_limiter.reserve_retry_after
          raise Integrations::RateLimitError.new(
            "Integrations::YampiAdapter: limite de requisições atingido",
            retry_after: retry_after
          )
        else
          raise Integrations::ApiError,
            "Integrations::YampiAdapter: resposta inesperada (HTTP #{response.status})"
        end
      end

      def raise_provider_reserve_if_needed!
        return unless rate_limiter.reserve_reached?

        raise Integrations::RateLimitError.new(
          "reserva de rate limit Yampi atingida",
          retry_after: rate_limiter.reserve_retry_after
        )
      end

      def process_page(raw_carts)
        @api_records_received += raw_carts.size

        raw_carts.each do |raw_cart|
          timestamp = cursor_timestamp_for(raw_cart)

          unless inside_cursor_window?(raw_cart, timestamp)
            @outside_cursor_window_count += 1
            next
          end

          @records_inside_cursor_window += 1
          observe_cursor_timestamp(timestamp)
          process_cart(raw_cart)
        end
      end

      def process_cart(raw_cart)
        event = PollingEvent.new(tenant: tenant, payload: raw_cart, event_type: "cart.polling", integration: integration)
        normalized = Integrations::Normalizers::YampiCartNormalizer.call(event)
        external_id = normalized[:external_id].to_s

        if external_id.blank?
          record_ignored(nil, "sem identificador externo")
          return
        end

        if seen_external_ids.include?(external_id)
          record_ignored(external_id, "duplicado na mesma execução")
          return
        end
        seen_external_ids << external_id

        result = Integrations::Carts::UpsertCart.call(tenant: tenant, normalized: normalized, provider: "yampi")
        if result.success?
          if result.created?
            @created_count += 1
            record_processed(external_id, "created")
          else
            @updated_count += 1
            record_processed(external_id, "updated")
          end
        else
          @error_count += 1
          item_errors << { external_id: external_id, message: result.error_message || "erro desconhecido" }
          record_processed(external_id, "error")
        end
      rescue => e
        @error_count += 1
        external_id = raw_cart["id"]&.to_s
        item_errors << { external_id: external_id, message: e.message }
        record_processed(external_id, "error")
      end

      def inside_cursor_window?(raw_cart, timestamp)
        return true if sync_mode == "backfill"

        unless timestamp
          record_ignored(raw_cart["id"]&.to_s, "sem created_at")
          return false
        end

        timestamp.between?(cursor_from, cursor_to)
      end

      def observe_cursor_timestamp(timestamp)
        return unless timestamp

        timestamp = timestamp.utc
        @max_seen_cursor_at = timestamp if @max_seen_cursor_at.nil? || timestamp > @max_seen_cursor_at
      end

      def cursor_timestamp_for(raw_cart)
        parse_yampi_timestamp(raw_cart["created_at"])
      end

      def parse_yampi_timestamp(value)
        raw_value = value.is_a?(Hash) ? value["date"] : value
        return nil if raw_value.blank?

        Time.zone.parse(raw_value.to_s)&.utc
      rescue ArgumentError, TypeError
        nil
      end

      def record_ignored(external_id, reason)
        @ignored_count += 1
        ignored_examples << { external_id: external_id, reason: reason } if ignored_examples.size < 10
        record_processed(external_id, "ignored")
      end

      def record_processed(external_id, outcome)
        return if processed_examples.size >= 20

        processed_examples << { external_id: external_id, outcome: outcome }
      end

      def date_filter
        "created_at:#{api_date_from}|#{api_date_to}"
      end

      def api_date_from
        cursor_from.to_date.iso8601
      end

      def api_date_to
        cursor_to.to_date.iso8601
      end

      def wait_for_one_request_per_second
        return unless @last_request_at

        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @last_request_at
        sleep(1.0 - elapsed) if elapsed < 1.0
      ensure
        @last_request_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def start_log
        IntegrationSyncLog.create!(
          tenant: tenant,
          integration: integration,
          direction: "inbound",
          action: "yampi_cart_polling",
          status: "pending",
          started_at: started_at,
          metadata: base_metadata
        )
      end

      def finish_log(status:, error_message: nil)
        return unless log

        finished_at = Time.current
        duration_ms = ((finished_at - started_at) * 1000).round
        log.update!(
          status: status,
          finished_at: finished_at,
          duration_ms: duration_ms,
          error_message: error_message,
          metadata: log.metadata.merge(count_metadata).merge(duration_ms: duration_ms)
        )
      end

      def base_metadata
        {
          trigger: trigger,
          channel: "yampi",
          channel_credential_id: channel_credential.id,
          sync_mode: sync_mode,
          window_from: cursor_from.iso8601,
          window_to: cursor_to.iso8601,
          cursor_source_field: "created_at",
          incremental_created_at_lookback_days: INCREMENTAL_CREATED_AT_LOOKBACK_DAYS,
          api_date_from: api_date_from,
          api_date_to: api_date_to,
          previous_cursor_at: previous_cursor_at&.iso8601
        }
      end

      def count_metadata
        {
          new_cursor_at: @new_cursor_at&.iso8601,
          max_seen_cursor_at: @max_seen_cursor_at&.iso8601,
          pages_fetched: @pages_fetched,
          api_requests_count: @api_requests_count,
          api_records_received: @api_records_received,
          records_inside_cursor_window: @records_inside_cursor_window,
          outside_cursor_window_count: @outside_cursor_window_count,
          created_count: @created_count,
          updated_count: @updated_count,
          ignored_count: @ignored_count,
          error_count: @error_count,
          rate_limit_limit: rate_limiter.last_limit,
          rate_limit_remaining: rate_limiter.last_remaining,
          rate_limited: @rate_limited,
          retry_after: retry_after,
          lock_acquired: @lock_acquired,
          processed_examples: processed_examples,
          ignored_examples: ignored_examples,
          errors: item_errors.first(10)
        }
      end

      def result(outcome, error_message, retry_after: nil)
        Result.new(outcome: outcome, error_message: error_message, retry_after: retry_after, metadata: count_metadata)
      end

      def next_cursor_at
        if @max_seen_cursor_at
          observed_cursor_at = [ @max_seen_cursor_at, cursor_to ].compact.min
          return [ observed_cursor_at, previous_cursor_at ].compact.max
        end

        return previous_cursor_at if previous_cursor_at.present?

        cursor_to
      end

      def error_count = @error_count
      def item_errors = @item_errors
      def ignored_examples = @ignored_examples
      def processed_examples = @processed_examples
      def lock_acquired = @lock_acquired
    end
  end
end
