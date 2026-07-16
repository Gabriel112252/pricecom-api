module Integrations
  module Lucrofrete
    # Syncs LucroFrete's GET /api/reports/orders into Order#real_freight_cost.
    #
    # This endpoint returns real orders already matched by LucroFrete
    # internally, including match_status. It is now the authoritative source
    # for LucroFrete real freight cost. Raw /api/logs quote polling remains
    # available for quote analysis, but must not write real_freight_cost.
    class OrdersSyncService
      MODES = %w[backfill incremental].freeze
      DEFAULT_PER_PAGE = 50
      INCREMENTAL_DAYS = 2
      BACKFILL_PAGE_SLEEP = 60
      MAX_EXAMPLES = 10

      Result = Struct.new(:outcome, :synced_count, :error_message, :metadata, keyword_init: true) do
        def success? = outcome == :success
        def error?   = outcome == :error
        def skipped? = outcome == :skipped
      end

      def self.call(channel_credential, mode:, start_date: nil, end_date: nil, page: 1, per_page: DEFAULT_PER_PAGE, trigger: "scheduled")
        new(
          channel_credential,
          mode: mode,
          start_date: start_date,
          end_date: end_date,
          page: page,
          per_page: per_page,
          trigger: trigger
        ).call
      end

      def initialize(channel_credential, mode:, start_date: nil, end_date: nil, page: 1, per_page: DEFAULT_PER_PAGE, trigger: "scheduled")
        @channel_credential = channel_credential
        @tenant = channel_credential.tenant
        @mode = mode.to_s
        @start_date = start_date
        @end_date = end_date
        @first_page = [ page.to_i, 1 ].max
        @per_page = per_page.to_i.positive? ? per_page.to_i : DEFAULT_PER_PAGE
        @trigger = trigger
        @integration = tenant.integrations.active.find_by(provider: "lucrofrete")
        @client = Integrations::LucrofreteClient.new(channel_credential)
        @started_at = Time.current
        reset_counts
      end

      def call
        validate_mode!
        @window_from, @window_to = resolve_window
        @log = start_log

        unless freight_sync_enabled?
          finish_log(status: "skipped", error_message: "freight nao esta configurado para lucrofrete")
          return result(:skipped, nil)
        end

        @channel = Channel.ensure_for!(tenant, "yampi")
        fetch_and_process_pages

        channel_credential.update!(last_synced_at: Time.current, status: "active")
        finish_log(status: item_errors.empty? ? "success" : "error", error_message: item_errors.first&.fetch(:message, nil))
        result(item_errors.empty? ? :success : :error, item_errors.first&.fetch(:message, nil))
      rescue Integrations::AuthenticationError => e
        channel_credential.update!(status: "error")
        finish_log(status: "error", error_message: e.message)
        result(:error, e.message)
      rescue Integrations::ApiError, Integrations::RateLimitError, ArgumentError => e
        finish_log(status: "error", error_message: e.message)
        result(:error, e.message)
      rescue => e
        finish_log(status: "error", error_message: e.message)
        result(:error, e.message)
      end

      private

      attr_reader :channel_credential, :tenant, :mode, :trigger, :integration, :client,
        :started_at, :log, :window_from, :window_to, :channel, :per_page,
        :item_errors

      def reset_counts
        @pages_processed = 0
        @orders_received = 0
        @matched_count = 0
        @updated_count = 0
        @already_up_to_date_count = 0
        @not_found_count = 0
        @unmatched_count = 0
        @invalid_cost_count = 0
        @total_orders_reported = nil
        @total_pages = nil
        @estimated_minimum_sleep_seconds = 0
        @actual_sleep_seconds = 0
        @item_errors = []
        @updated_examples = []
        @not_found_examples = []
        @unmatched_examples = []
        @invalid_cost_examples = []
        @backfill_plan_logged = false
      end

      def validate_mode!
        return if MODES.include?(mode)

        raise ArgumentError, "modo LucroFrete invalido: #{mode.inspect}; use #{MODES.join(' ou ')}"
      end

      def resolve_window
        to = parse_date(@end_date) || Date.current
        from =
          if mode == "backfill"
            parse_date(@start_date) || raise(ArgumentError, "start_date/SINCE e obrigatorio no modo backfill")
          else
            parse_date(@start_date) || (to - INCREMENTAL_DAYS)
          end

        raise ArgumentError, "start_date nao pode ser maior que end_date" if from > to

        [ from, to ]
      end

      def parse_date(value)
        return nil if value.blank?

        value.to_date
      rescue ArgumentError, TypeError, NoMethodError
        raise ArgumentError, "data invalida para LucroFrete: #{value.inspect}"
      end

      def freight_sync_enabled?
        DataSourceConfig.source_for(tenant, "freight") == "lucrofrete"
      end

      def fetch_and_process_pages
        page = @first_page

        loop do
          body = client.fetch_orders_report(start_date: window_from, end_date: window_to, page: page, per_page: per_page)
          @pages_processed += 1

          orders = extract_orders(body)
          @orders_received += orders.size
          remember_report_totals(body)
          log_backfill_plan_once

          orders.each { |raw_order| process_report_order(raw_order) }

          break unless fetch_next_page?(page, orders)

          page += 1
          sleep_before_next_page(page)
        end
      end

      def extract_orders(body)
        unless body.is_a?(Hash)
          raise Integrations::ApiError, "LucroFrete reports/orders retornou #{body.class}, esperado Hash"
        end

        orders = body["orders"]
        return orders if orders.is_a?(Array)

        raise Integrations::ApiError, "LucroFrete reports/orders nao retornou array em 'orders'"
      end

      def remember_report_totals(body)
        total = body["total"].to_i
        response_per_page = body["per_page"].to_i
        effective_per_page = response_per_page.positive? ? response_per_page : per_page

        @total_orders_reported = total if body.key?("total")
        @total_pages ||= total.positive? ? (total.to_f / effective_per_page).ceil : 0 if body.key?("total")
      end

      def log_backfill_plan_once
        return unless mode == "backfill"
        return if @backfill_plan_logged

        @estimated_minimum_sleep_seconds = [ @total_pages.to_i - 1, 0 ].max * BACKFILL_PAGE_SLEEP
        Rails.logger.info(
          "[Integrations::Lucrofrete::OrdersSyncService] backfill tenant=#{tenant.slug} " \
          "periodo=#{window_from}..#{window_to} total_orders=#{@total_orders_reported || 'desconhecido'} " \
          "total_pages=#{@total_pages || 'desconhecido'} " \
          "estimated_minimum_sleep=#{format_duration(@estimated_minimum_sleep_seconds)}"
        )
        log.update!(metadata: log.metadata.merge(plan_metadata)) if log
        @backfill_plan_logged = true
      end

      def fetch_next_page?(page, orders)
        return false if @total_pages && page >= @total_pages
        return false if orders.empty?

        orders.size >= per_page
      end

      def sleep_before_next_page(next_page)
        return unless mode == "backfill"

        Rails.logger.info(
          "[Integrations::Lucrofrete::OrdersSyncService] backfill tenant=#{tenant.slug} " \
          "sleep=#{BACKFILL_PAGE_SLEEP}s antes da pagina #{next_page}"
        )
        sleep(BACKFILL_PAGE_SLEEP)
        @actual_sleep_seconds += BACKFILL_PAGE_SLEEP
      end

      def process_report_order(raw_order)
        unless raw_order.is_a?(Hash)
          record_item_error(raw_order, "entrada de pedido nao e Hash")
          return
        end

        raw = raw_order.with_indifferent_access
        order_number = raw["order_number"].to_s.strip
        match_status = raw["match_status"].to_s

        unless matched_status?(match_status)
          @unmatched_count += 1
          record_unmatched_example(raw, order_number, match_status)
          return
        end

        @matched_count += 1
        order = find_local_order(order_number)
        unless order
          @not_found_count += 1
          record_not_found_example(raw, order_number)
          return
        end

        cost = parse_money(raw["freight_cost"])
        unless cost
          @invalid_cost_count += 1
          record_invalid_cost_example(raw, order)
          return
        end

        rounded_cost = cost.round(2)
        if order.real_freight_cost.present? && BigDecimal(order.real_freight_cost.to_s).round(2) == rounded_cost
          @already_up_to_date_count += 1
          return
        end

        order.update!(real_freight_cost: rounded_cost)
        @updated_count += 1
        record_updated_example(raw, order, rounded_cost)
      rescue => e
        record_item_error(raw_order, e.message)
      end

      def matched_status?(value)
        value.to_s.casecmp?("matched")
      end

      def find_local_order(order_number)
        return nil if order_number.blank?

        tenant.orders.find_by(channel: channel, order_number: order_number)
      end

      def parse_money(value)
        return nil if value.nil?

        BigDecimal(value.to_s)
      rescue ArgumentError
        nil
      end

      def record_updated_example(raw, order, rounded_cost)
        return if @updated_examples.size >= MAX_EXAMPLES

        @updated_examples << {
          lucrofrete_order_id: raw["id"],
          quote_log_id: raw["quote_log_id"],
          order_id: order.id,
          order_number: order.order_number,
          real_freight_cost: rounded_cost.to_s
        }
      end

      def record_not_found_example(raw, order_number)
        return if @not_found_examples.size >= MAX_EXAMPLES

        @not_found_examples << {
          lucrofrete_order_id: raw["id"],
          order_number: order_number.presence,
          quote_log_id: raw["quote_log_id"],
          reason: order_number.blank? ? "missing_order_number" : "order_not_found"
        }
        Rails.logger.info(
          "[Integrations::Lucrofrete::OrdersSyncService] pedido local nao encontrado " \
          "tenant=#{tenant.slug} order_number=#{order_number.presence || '(blank)'}"
        )
      end

      def record_unmatched_example(raw, order_number, match_status)
        return if @unmatched_examples.size >= MAX_EXAMPLES

        @unmatched_examples << {
          lucrofrete_order_id: raw["id"],
          order_number: order_number.presence,
          match_status: match_status.presence,
          quote_log_id: raw["quote_log_id"]
        }
      end

      def record_invalid_cost_example(raw, order)
        return if @invalid_cost_examples.size >= MAX_EXAMPLES

        @invalid_cost_examples << {
          lucrofrete_order_id: raw["id"],
          order_id: order.id,
          order_number: order.order_number,
          freight_cost: raw["freight_cost"]
        }
      end

      def record_item_error(raw_order, message)
        item_errors << {
          lucrofrete_order_id: raw_order.is_a?(Hash) ? raw_order["id"] : nil,
          order_number: raw_order.is_a?(Hash) ? raw_order["order_number"] : nil,
          message: message
        }
      end

      def start_log
        IntegrationSyncLog.create!(
          tenant: tenant,
          integration: integration,
          direction: "inbound",
          action: "lucrofrete_orders_sync",
          status: "pending",
          started_at: started_at,
          metadata: {
            trigger: trigger,
            mode: mode,
            channel: "lucrofrete",
            local_order_channel: "yampi",
            channel_credential_id: channel_credential.id,
            source_endpoint: "reports/orders",
            window_from: window_from.iso8601,
            window_to: window_to.iso8601,
            per_page: per_page
          }
        )
      end

      def finish_log(status:, error_message: nil)
        return unless log

        finished_at = Time.current
        log.update!(
          status: status,
          finished_at: finished_at,
          duration_ms: ((finished_at - started_at) * 1000).round,
          error_message: error_message,
          metadata: log.metadata.merge(count_metadata)
        )
      end

      def count_metadata
        {
          mode: mode,
          pages_processed: @pages_processed,
          total_pages: @total_pages,
          total_orders_reported: @total_orders_reported,
          estimated_minimum_sleep_seconds: @estimated_minimum_sleep_seconds,
          actual_sleep_seconds: @actual_sleep_seconds,
          orders_received: @orders_received,
          matched_count: @matched_count,
          updated_count: @updated_count,
          synced_count: @updated_count,
          already_up_to_date_count: @already_up_to_date_count,
          not_found_count: @not_found_count,
          unmatched_count: @unmatched_count,
          invalid_cost_count: @invalid_cost_count,
          error_count: item_errors.size,
          updated_examples: @updated_examples,
          not_found_examples: @not_found_examples,
          unmatched_examples: @unmatched_examples,
          invalid_cost_examples: @invalid_cost_examples,
          errors: item_errors.first(MAX_EXAMPLES)
        }
      end

      def plan_metadata
        {
          total_pages: @total_pages,
          total_orders_reported: @total_orders_reported,
          estimated_minimum_sleep_seconds: @estimated_minimum_sleep_seconds,
          estimated_minimum_sleep_human: format_duration(@estimated_minimum_sleep_seconds),
          backfill_sleep_seconds_per_page: BACKFILL_PAGE_SLEEP
        }
      end

      def format_duration(seconds)
        minutes = (seconds.to_i / 60.0).ceil
        return "0min" if minutes.zero?

        "#{minutes}min"
      end

      def result(outcome, error_message)
        Result.new(outcome: outcome, synced_count: @updated_count, error_message: error_message, metadata: count_metadata)
      end
    end
  end
end
