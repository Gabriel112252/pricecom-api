module Integrations
  module Yampi
    class OrdersPollingService
      BACKFILL_DAYS = 30
      INCREMENTAL_OVERLAP = 10.minutes
      LIMIT = Integrations::YampiAdapter::ORDERS_LIMIT

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
        @lock = PollingLock.new(channel_credential)
        @started_at = Time.current
        @cursor_to = @started_at.utc
        @previous_cursor_at = channel_credential.orders_sync_cursor_at&.utc
        @sync_mode = previous_cursor_at.present? ? "incremental" : "backfill"
        @cursor_from = sync_mode == "incremental" ? previous_cursor_at - INCREMENTAL_OVERLAP : cursor_to - BACKFILL_DAYS.days
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
          finish_log(status: "skipped", error_message: "polling já em execução")
          return result(:skipped, "polling já em execução")
        end

        @lock_acquired = true
        Channel.ensure_for!(tenant, "yampi")
        fetch_and_process_pages

        if error_count.positive?
          finish_log(status: "error", error_message: item_errors.first&.fetch(:message, nil))
          return result(:error, item_errors.first&.fetch(:message, nil))
        end

        channel_credential.update!(orders_sync_cursor_at: cursor_to, last_synced_at: Time.current, status: "active")
        @new_cursor_at = cursor_to
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

      def initialize_counters
        @pages_fetched = 0
        @api_requests_count = 0
        @api_records_received = 0
        @records_inside_cursor_window = 0
        @outside_cursor_window_count = 0
        @created_count = 0
        @updated_count = 0
        @unchanged_count = 0
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

          response = adapter.fetch_orders_page(page: page, date_filter: date_filter, limit: LIMIT, skip_cache: true)
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

      def process_page(raw_orders)
        @api_records_received += raw_orders.size

        raw_orders.each do |raw_order|
          unless inside_cursor_window?(raw_order)
            @outside_cursor_window_count += 1
            next
          end

          @records_inside_cursor_window += 1
          process_order(raw_order)
        end
      end

      def process_order(raw_order)
        event = PollingEvent.new(tenant: tenant, payload: raw_order, event_type: "order.polling", integration: integration)
        normalized = Integrations::Normalizers::YampiOrderNormalizer.call(event)
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

        existing_order = find_existing_yampi_order(external_id)
        if unchanged_order?(existing_order, normalized)
          @unchanged_count += 1
          record_processed(external_id, "unchanged")
          return
        end

        result = Integrations::Processors::YampiOrderProcessor.call(event)
        if result.outcome == :success
          if existing_order
            @updated_count += 1
            record_processed(external_id, "updated")
          else
            @created_count += 1
            record_processed(external_id, "created")
          end
        elsif result.outcome == :skipped
          record_ignored(external_id, result.error_message || "ignorado pelo processor")
        else
          @error_count += 1
          item_errors << { external_id: external_id, message: result.error_message || "erro desconhecido" }
          record_processed(external_id, "error")
        end
      rescue => e
        @error_count += 1
        external_id = raw_order["id"]&.to_s || raw_order["order_id"]&.to_s
        item_errors << { external_id: external_id, message: e.message }
        record_processed(external_id, "error")
      end

      def inside_cursor_window?(raw_order)
        return true if sync_mode == "backfill"

        updated_at = parse_yampi_timestamp(raw_order["updated_at"])
        unless updated_at
          record_ignored((raw_order["id"] || raw_order["order_id"])&.to_s, "sem updated_at")
          return false
        end

        updated_at.between?(cursor_from, cursor_to)
      end

      def parse_yampi_timestamp(value)
        raw_value = value.is_a?(Hash) ? value["date"] : value
        return nil if raw_value.blank?

        Time.zone.parse(raw_value.to_s)&.utc
      rescue ArgumentError, TypeError
        nil
      end

      def unchanged_order?(order, normalized)
        return false unless order
        return false if order.stock_deducted_at.blank?
        return false unless order.order_type == "sale"

        persisted_order_attrs(order) == normalized_order_attrs(normalized) &&
          persisted_items(order) == normalized_items(normalized)
      end

      def persisted_order_attrs(order)
        attrs = {
          order_number: order.order_number.to_s,
          status: order.status.to_s,
          payment_method: order.payment_method.to_s,
          customer_name: order.customer_name.to_s,
          customer_tag: order.customer_tag.to_s,
          state: order.state.to_s,
          order_type: order.order_type.to_s,
          refund_amount: decimal_string(order.refund_amount),
          nf_number: order.nf_number.to_s,
          nf_gross_value: decimal_string(order.nf_gross_value),
          nf_discount: decimal_string(order.nf_discount),
          nf_freight: decimal_string(order.nf_freight),
          gross_value: decimal_string(order.gross_value),
          freight: decimal_string(order.freight),
          discount: decimal_string(order.discount),
          items_qty: order.items_qty.to_i,
          ordered_at: order.ordered_at&.utc&.to_i
        }
        attrs[:coupon_code] = order.coupon_code.to_s if order_has_coupons?
        attrs[:coupon_discount] = decimal_string(order.coupon_discount) if order_has_coupons?
        attrs
      end

      def normalized_order_attrs(normalized)
        attrs = {
          order_number: normalized[:order_number].to_s,
          status: normalized[:status].to_s,
          payment_method: normalized[:payment_method].to_s,
          customer_name: normalized[:customer_name].to_s,
          customer_tag: normalized[:customer_tag].to_s,
          state: normalized[:state].to_s,
          order_type: (normalized[:order_type] || "sale").to_s,
          refund_amount: decimal_string(normalized[:refund_amount]),
          nf_number: normalized[:nf_number].to_s,
          nf_gross_value: decimal_string(normalized[:nf_gross_value]),
          nf_discount: decimal_string(normalized[:nf_discount]),
          nf_freight: decimal_string(normalized[:nf_freight]),
          gross_value: decimal_string(normalized[:gross_value]),
          freight: decimal_string(normalized[:freight]),
          discount: decimal_string(normalized[:discount]),
          items_qty: normalized[:items].sum { |item| item[:quantity].to_i },
          ordered_at: normalized[:ordered_at]&.utc&.to_i
        }
        attrs[:coupon_code] = normalized[:coupon_code].to_s if order_has_coupons?
        attrs[:coupon_discount] = decimal_string(normalized[:coupon_discount]) if order_has_coupons?
        attrs
      end

      def persisted_items(order)
        order.order_items.order(:id).map do |item|
          {
            sku: item.sku.to_s,
            name: item.name.to_s,
            quantity: item.quantity.to_i,
            unit_price: decimal_string(item.unit_price),
            unit_cost: decimal_string(item.unit_cost),
            discount: decimal_string(item.discount),
            is_gift: item.is_gift == true,
            nf_unit_price: decimal_string(item.nf_unit_price)
          }
        end
      end

      def normalized_items(normalized)
        normalized[:items].map do |item|
          {
            sku: item[:sku].to_s,
            name: item[:name].to_s,
            quantity: item[:quantity].to_i,
            unit_price: decimal_string(item[:unit_price]),
            unit_cost: decimal_string(item[:unit_cost]),
            discount: decimal_string(item[:discount]),
            is_gift: item[:is_gift] == true,
            nf_unit_price: decimal_string(item[:nf_unit_price])
          }
        end
      end

      def decimal_string(value)
        BigDecimal(value.to_s.presence || "0").round(2).to_s("F")
      rescue ArgumentError
        "0.0"
      end

      def order_has_coupons?
        @order_has_coupons ||= Order.column_names.include?("coupon_code")
      end

      def find_existing_yampi_order(external_id)
        tenant.orders.joins(:channel).find_by(external_id: external_id, channels: { platform: "yampi" })
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
        field = sync_mode == "backfill" ? "created_at" : "updated_at"
        "#{field}:#{api_date_from}|#{api_date_to}"
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
          action: "yampi_order_polling",
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
          api_date_from: api_date_from,
          api_date_to: api_date_to,
          previous_cursor_at: previous_cursor_at&.iso8601
        }
      end

      def count_metadata
        {
          new_cursor_at: @new_cursor_at&.iso8601,
          pages_fetched: @pages_fetched,
          api_requests_count: @api_requests_count,
          api_records_received: @api_records_received,
          records_inside_cursor_window: @records_inside_cursor_window,
          outside_cursor_window_count: @outside_cursor_window_count,
          created_count: @created_count,
          updated_count: @updated_count,
          unchanged_count: @unchanged_count,
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

      def pages_fetched = @pages_fetched
      def api_requests_count = @api_requests_count
      def api_records_received = @api_records_received
      def records_inside_cursor_window = @records_inside_cursor_window
      def created_count = @created_count
      def updated_count = @updated_count
      def unchanged_count = @unchanged_count
      def ignored_count = @ignored_count
      def error_count = @error_count
      def item_errors = @item_errors
      def ignored_examples = @ignored_examples
      def processed_examples = @processed_examples
      def lock_acquired = @lock_acquired
    end
  end
end
