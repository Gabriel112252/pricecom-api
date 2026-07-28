module Integrations
  module Tiktok
    # Persists an aggregated snapshot of TikTok Shop's Get Shop Performance
    # 202405 (analytics/202405/shop/performance — see
    # TiktokAdapter#fetch_shop_analytics) for a rolling window into
    # ShopAnalyticsSnapshot. There is no per-order granularity in this API —
    # see CreateShopAnalyticsSnapshots for why this doesn't fit orders.
    #
    # NOT wired into any cron yet (see config/schedule.yml,
    # tiktok_shop_analytics_sync_dispatch commented out) — the analytics
    # scope isn't confirmed granted for every tenant and the response shape
    # is still only SDK-guessed beyond the gmv_breakdowns[].type values
    # (see TiktokAdapter#fetch_shop_analytics). Run manually via console
    # first: Integrations::Tiktok::ShopAnalyticsSyncService.call(channel_credential).
    class ShopAnalyticsSyncService
      DEFAULT_WINDOW_DAYS = 30

      Result = Struct.new(:outcome, :error_message, :metadata, keyword_init: true) do
        def success? = outcome == :success
        def error? = outcome == :error
        def skipped? = outcome == :skipped
      end

      def self.call(channel_credential, window_days: DEFAULT_WINDOW_DAYS, trigger: "manual")
        new(channel_credential, window_days: window_days, trigger: trigger).call
      end

      def initialize(channel_credential, window_days: DEFAULT_WINDOW_DAYS, trigger: "manual")
        @channel_credential = channel_credential
        @tenant = channel_credential.tenant
        @window_days = window_days.presence || DEFAULT_WINDOW_DAYS
        @trigger = trigger
        @adapter = Integrations::TiktokAdapter.new(channel_credential.credentials)
        @started_at = Time.current
      end

      def call
        @log = start_log

        @channel = tenant.channels.find_by(platform: "tiktok")
        unless channel
          finish_log(status: "skipped", error_message: "canal tiktok não encontrado")
          return result(:skipped, "canal tiktok não encontrado")
        end

        snapshot = sync_snapshot

        finish_log(status: "success", snapshot: snapshot)
        result(:success, nil, snapshot)
      rescue Integrations::AuthenticationError => e
        channel_credential.update!(status: "error")
        finish_log(status: "error", error_message: e.message)
        result(:error, e.message)
      rescue Integrations::RateLimitError => e
        finish_log(status: "error", error_message: "rate_limited: #{e.message}")
        raise
      end

      private

      attr_reader :channel_credential, :tenant, :window_days, :trigger, :adapter, :channel, :started_at, :log

      def date_from
        @date_from ||= window_days.to_i.days.ago.to_date
      end

      def date_to
        @date_to ||= Date.current
      end

      def sync_snapshot
        data = adapter.fetch_shop_analytics(date_from: date_from, date_to: date_to, granularity: "ALL")
        interval = data.dig("performance", 0, "intervals", 0) || {}

        persist_snapshot(interval, data)
      end

      def persist_snapshot(interval, raw_response)
        snapshot = tenant.shop_analytics_snapshots.find_or_initialize_by(
          channel: channel, period_start: date_from, period_end: date_to
        )

        breakdowns = Array(interval["gmv_breakdowns"])

        snapshot.assign_attributes(
          gmv_total:                 to_f(interval.dig("gmv", "amount")),
          gmv_live:                  gmv_for(breakdowns, "LIVE"),
          gmv_video:                 gmv_for(breakdowns, "VIDEO"),
          gmv_product_card:          gmv_for(breakdowns, "PRODUCT_CARD"),
          refunds_amount:            to_f(interval.dig("refunds", "amount")),
          orders:                    interval["orders"].to_i,
          buyers:                    interval["buyers"].to_i,
          product_impressions:       interval["product_impressions"].to_i,
          product_page_views:        interval["product_page_views"].to_i,
          cancellations_and_returns: interval["cancellations_and_returns"].to_i,
          raw_response:              raw_response,
          synced_at:                 Time.current
        )
        snapshot.save!
        snapshot
      end

      # Content-type breakdown per gmv_breakdowns[].type (LIVE/VIDEO/
      # PRODUCT_CARD, confirmed 2026-07-28). Any other/unknown type is
      # simply not attributed to one of the three named columns — it still
      # counts in gmv_total (read straight from the API's own gmv.amount,
      # never recomputed as a sum of the three), so nothing is silently
      # dropped from the total, only from the per-format split.
      def gmv_for(breakdowns, type)
        entry = breakdowns.find { |row| row["type"] == type }
        to_f(entry&.dig("amount"))
      end

      def to_f(value)
        value.nil? ? 0.0 : value.to_s.gsub(",", ".").to_f
      end

      def start_log
        IntegrationSyncLog.create!(
          tenant:      tenant,
          direction:   "inbound",
          action:      "tiktok_shop_analytics_sync",
          status:      "pending",
          started_at:  started_at,
          metadata: {
            trigger:               trigger,
            channel_credential_id: channel_credential.id,
            window_days:           window_days,
            date_from:             date_from.iso8601,
            date_to:               date_to.iso8601
          }
        )
      end

      def finish_log(status:, error_message: nil, snapshot: nil)
        return unless log

        finished_at = Time.current
        log.update!(
          status:        status,
          finished_at:   finished_at,
          duration_ms:   ((finished_at - started_at) * 1000).round,
          error_message: error_message,
          metadata:      log.metadata.merge(snapshot_id: snapshot&.id)
        )
      end

      def result(outcome, error_message, snapshot = nil)
        Result.new(outcome: outcome, error_message: error_message, metadata: { snapshot_id: snapshot&.id })
      end
    end
  end
end
