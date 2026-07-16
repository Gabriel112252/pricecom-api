module Integrations
  module Lucrofrete
    # Syncs LucroFrete's GET /api/reports/orders into Order#real_freight_cost
    # and freight_margin_dailies.
    #
    # This endpoint returns real orders already matched by LucroFrete
    # internally, including match_status. It is now the authoritative source
    # for LucroFrete real freight cost. Raw /api/logs quote polling remains
    # available for quote analysis, but must not write real_freight_cost.
    #
    # Channel-aware: local orders are matched by order_number in the Yampi
    # channel first (historical behavior), then tenant-wide — so TikTok Shop
    # (and future channels) shipments dispatched through the same carrier
    # account also get real_freight_cost and their own per-channel
    # freight_margin_dailies rows, which is what makes the dashboard's
    # "Margem de frete" gadget respond to the TikTok channel filter.
    class OrdersSyncService
      MODES = %w[backfill incremental].freeze
      DEFAULT_PER_PAGE = 50
      INCREMENTAL_DAYS = 2
      BACKFILL_PAGE_SLEEP = 120
      MAX_EXAMPLES = 10

      Result = Struct.new(:outcome, :synced_count, :error_message, :metadata, keyword_init: true) do
        def success? = outcome == :success
        def error?   = outcome == :error
        def skipped? = outcome == :skipped
      end

      def self.call(channel_credential, mode:, start_date: nil, end_date: nil, page: 1, per_page: DEFAULT_PER_PAGE, page_sleep: nil, trigger: "scheduled")
        new(
          channel_credential,
          mode: mode,
          start_date: start_date,
          end_date: end_date,
          page: page,
          per_page: per_page,
          page_sleep: page_sleep,
          trigger: trigger
        ).call
      end

      def initialize(channel_credential, mode:, start_date: nil, end_date: nil, page: 1, per_page: DEFAULT_PER_PAGE, page_sleep: nil, trigger: "scheduled")
        @channel_credential = channel_credential
        @tenant = channel_credential.tenant
        @mode = mode.to_s
        @start_date = start_date
        @end_date = end_date
        @first_page = [ page.to_i, 1 ].max
        @per_page = per_page.to_i.positive? ? per_page.to_i : DEFAULT_PER_PAGE
        @page_sleep_seconds = resolve_page_sleep(page_sleep)
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
        upsert_freight_margin_days

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
        :started_at, :log, :window_from, :window_to, :channel, :per_page, :page_sleep_seconds,
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
        @freight_margin_orders_count = 0
        @freight_margin_days_upserted = 0
        @freight_margin_skipped_count = 0
        @reports_upserted_count = 0
        @reports_skipped_count = 0
        @total_orders_reported = nil
        @total_pages = nil
        @estimated_minimum_sleep_seconds = 0
        @actual_sleep_seconds = 0
        @item_errors = []
        @daily_margin_totals = {}
        @updated_examples = []
        @not_found_examples = []
        @unmatched_examples = []
        @invalid_cost_examples = []
        @freight_margin_skipped_examples = []
        @reports_skipped_examples = []
        @backfill_plan_logged = false
      end

      def resolve_page_sleep(value)
        seconds = value.to_i
        seconds = BACKFILL_PAGE_SLEEP unless seconds.positive?
        [ seconds, 60 ].max
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

        @estimated_minimum_sleep_seconds = [ @total_pages.to_i - 1, 0 ].max * page_sleep_seconds
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
          "sleep=#{page_sleep_seconds}s antes da pagina #{next_page}"
        )
        sleep(page_sleep_seconds)
        @actual_sleep_seconds += page_sleep_seconds
      end

      def process_report_order(raw_order)
        unless raw_order.is_a?(Hash)
          record_item_error(raw_order, "entrada de pedido nao e Hash")
          return
        end

        raw = raw_order.with_indifferent_access
        order_number = raw["order_number"].to_s.strip
        match_status = raw["match_status"].to_s
        report = upsert_order_report(raw)

        unless matched_status?(match_status)
          @unmatched_count += 1
          record_unmatched_example(raw, order_number, match_status)
          return
        end

        @matched_count += 1
        order = find_local_order(order_number)
        aggregate_freight_margin(raw, order)

        unless order
          @not_found_count += 1
          record_not_found_example(raw, order_number)
          return
        end

        link_order_report(report, order)
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

      # Yampi primeiro (comportamento histórico), com fallback tenant-wide
      # para os demais canais (ex: pedidos TikTok Shop despachados pela
      # mesma conta LucroFrete/transportadora). O fallback só aceita match
      # inequívoco — order_number repetido entre canais fica de fora.
      def find_local_order(order_number)
        return nil if order_number.blank?

        order = tenant.orders.find_by(channel: channel, order_number: order_number)
        return order if order

        candidates = tenant.orders.where(order_number: order_number).limit(2).to_a
        candidates.size == 1 ? candidates.first : nil
      end

      def parse_money(value)
        return nil if value.nil?

        BigDecimal(value.to_s)
      rescue ArgumentError
        nil
      end

      def upsert_order_report(raw)
        return nil unless order_reports_available?

        lucrofrete_order_id = raw["id"].to_s
        if lucrofrete_order_id.blank?
          record_order_report_skip(raw, "missing_lucrofrete_order_id")
          return nil
        end

        report = tenant.lucrofrete_order_reports.find_or_initialize_by(lucrofrete_order_id: lucrofrete_order_id)
        report.assign_attributes(
          channel: channel,
          shopify_order_id: raw["shopify_order_id"].presence&.to_s,
          order_number: raw["order_number"].to_s,
          order_created_at: parse_report_order_time(raw["order_created_at"]),
          customer_state: raw["customer_state"].presence&.to_s,
          customer_city: raw["customer_city"].presence&.to_s,
          customer_zipcode: raw["customer_zipcode"].presence&.to_s,
          total_order_value: parse_money(raw["total_order_value"]),
          total_items: raw["total_items"].presence&.to_i,
          freight_charged: parse_money(raw["freight_charged"]),
          freight_cost: parse_money(raw["freight_cost"]),
          margin_value: parse_money(raw["margin_value"]),
          margin_percent: parse_money(raw["margin_percent"]),
          is_free_shipping: raw["is_free_shipping"],
          shipping_method_title: raw["shipping_method_title"].presence&.to_s,
          slot_name: raw["slot_name"].presence&.to_s,
          carrier_name: raw["carrier_name"].presence&.to_s,
          match_status: raw["match_status"].presence&.to_s,
          quote_log_id: raw["quote_log_id"].presence&.to_s,
          raw_payload: raw.to_h,
          synced_at: Time.current
        )
        report.save!
        @reports_upserted_count += 1
        report
      rescue => e
        record_order_report_skip(raw, e.message)
        nil
      end

      def link_order_report(report, order)
        return unless report && order
        return if report.order_id == order.id

        report.update!(order: order)
      rescue => e
        record_order_report_skip(report.raw_payload || {}, "link_order_failed: #{e.message}")
      end

      def order_reports_available?
        return @order_reports_available if defined?(@order_reports_available)

        @order_reports_available = LucrofreteOrderReport.table_exists?
      rescue StandardError
        @order_reports_available = false
      end

      # A agregação diária é por canal do pedido local casado. Pedidos do
      # canal padrão (yampi) — e os não encontrados localmente, como sempre
      # foi — usam os valores do próprio LucroFrete. Pedidos de outros
      # canais (ex: TikTok Shop) usam como "cobrado" o frete que o canal
      # cobrou do cliente (orders.freight ← payment.shipping_fee) e como
      # custo o valor real da transportadora vindo do LucroFrete; a margem
      # é recalculada dessa dupla.
      def aggregate_freight_margin(raw, order = nil)
        return unless freight_margin_available?

        bucket_channel = order && order.channel_id != channel.id ? order.channel : channel
        date = parse_report_order_date(raw["order_created_at"])
        cost = parse_money(raw["freight_cost"])

        if bucket_channel == channel
          charged = parse_money(raw["freight_charged"])
          margin = parse_money(raw["margin_value"])
          margin ||= charged - cost if charged && cost
        else
          charged = parse_money(order.freight)
          margin = charged - cost if charged && cost
        end

        unless date && charged && cost && margin
          record_freight_margin_skip(raw, "invalid_daily_margin_fields")
          return
        end

        totals = daily_margin_totals_for(bucket_channel, date)
        totals[:order_count] += 1
        totals[:freight_charged] += charged
        totals[:freight_cost] += cost
        totals[:margin_value] += margin
        totals[:free_shipping_count] += 1 if raw["is_free_shipping"] == true
        @freight_margin_orders_count += 1
      rescue => e
        record_freight_margin_skip(raw, e.message)
      end

      def parse_report_order_date(value)
        return nil if value.blank?

        parsed_time = parse_report_order_time(value)
        return parsed_time.to_date if parsed_time

        Date.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def parse_report_order_time(value)
        return nil if value.blank?

        Time.zone.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def daily_margin_totals_for(bucket_channel, date)
        @daily_margin_totals[[ bucket_channel, date ]] ||= {
          order_count: 0,
          freight_charged: BigDecimal("0"),
          freight_cost: BigDecimal("0"),
          margin_value: BigDecimal("0"),
          free_shipping_count: 0
        }
      end

      # O canal padrão (yampi) mantém a semântica histórica: toda data da
      # janela é reescrita, zerando dias que sumiram do report. Os demais
      # canais só reescrevem datas agregadas NESTA execução — a presença
      # deles no bucket depende do pedido local já ter sido ingerido pelo
      # polling do canal, então zerar a janela inteira apagaria dias válidos
      # num run em que o polling estivesse atrasado.
      def upsert_freight_margin_days
        return unless freight_margin_available?

        existing_default_by_date = tenant.freight_margin_dailies
          .where(channel: channel, date: window_from..window_to)
          .index_by(&:date)
        default_dates = (@daily_margin_totals.keys.select { |ch, _| ch == channel }.map(&:last) +
          existing_default_by_date.keys).uniq
        keys = (@daily_margin_totals.keys + default_dates.map { |date| [ channel, date ] }).uniq.sort_by { |ch, date| [ ch.id, date ] }

        keys.each do |bucket_channel, date|
          totals = @daily_margin_totals[[ bucket_channel, date ]] || daily_margin_totals_for(bucket_channel, date)
          row = (bucket_channel == channel && existing_default_by_date[date]) ||
            tenant.freight_margin_dailies.find_or_initialize_by(channel: bucket_channel, date: date)
          charged = totals[:freight_charged]
          margin = totals[:margin_value]

          row.assign_attributes(
            order_count: totals[:order_count],
            freight_charged: charged.round(2),
            freight_cost: totals[:freight_cost].round(2),
            margin_value: margin.round(2),
            margin_percent: charged.positive? ? (margin / charged * 100).round(2) : nil,
            free_shipping_count: totals[:free_shipping_count],
            synced_at: Time.current
          )
          row.save!
          @freight_margin_days_upserted += 1
        end
      end

      def freight_margin_available?
        return @freight_margin_available if defined?(@freight_margin_available)

        @freight_margin_available = FreightMarginDaily.table_exists?
      rescue StandardError
        @freight_margin_available = false
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

      def record_freight_margin_skip(raw, reason)
        @freight_margin_skipped_count += 1
        return if @freight_margin_skipped_examples.size >= MAX_EXAMPLES

        @freight_margin_skipped_examples << {
          lucrofrete_order_id: raw["id"],
          order_number: raw["order_number"],
          order_created_at: raw["order_created_at"],
          freight_charged: raw["freight_charged"],
          freight_cost: raw["freight_cost"],
          margin_value: raw["margin_value"],
          reason: reason
        }
      end

      def record_order_report_skip(raw, reason)
        @reports_skipped_count += 1
        return if @reports_skipped_examples.size >= MAX_EXAMPLES

        @reports_skipped_examples << {
          lucrofrete_order_id: raw["id"],
          order_number: raw["order_number"],
          reason: reason
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
            local_order_channel: "yampi (fallback tenant-wide para outros canais)",
            channel_credential_id: channel_credential.id,
            source_endpoint: "reports/orders",
            window_from: window_from.iso8601,
            window_to: window_to.iso8601,
            per_page: per_page,
            page_sleep_seconds: mode == "backfill" ? page_sleep_seconds : 0
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
          freight_margin_orders_count: @freight_margin_orders_count,
          freight_margin_days_upserted: @freight_margin_days_upserted,
          freight_margin_skipped_count: @freight_margin_skipped_count,
          reports_upserted_count: @reports_upserted_count,
          reports_skipped_count: @reports_skipped_count,
          error_count: item_errors.size,
          updated_examples: @updated_examples,
          not_found_examples: @not_found_examples,
          unmatched_examples: @unmatched_examples,
          invalid_cost_examples: @invalid_cost_examples,
          freight_margin_skipped_examples: @freight_margin_skipped_examples,
          reports_skipped_examples: @reports_skipped_examples,
          errors: item_errors.first(MAX_EXAMPLES)
        }
      end

      def plan_metadata
        {
          total_pages: @total_pages,
          total_orders_reported: @total_orders_reported,
          estimated_minimum_sleep_seconds: @estimated_minimum_sleep_seconds,
          estimated_minimum_sleep_human: format_duration(@estimated_minimum_sleep_seconds),
          backfill_sleep_seconds_per_page: page_sleep_seconds
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
