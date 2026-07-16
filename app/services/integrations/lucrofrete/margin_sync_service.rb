module Integrations
  module Lucrofrete
    # Syncs LucroFrete's /api/reports/timeline (REAL matched orders, not raw
    # quotes) into the local freight_margin_dailies table, so the dashboard
    # reads local data with the standard period/channel filters instead of
    # hitting the LucroFrete API on every page load.
    #
    # Window: first run (no rows for the tenant) backfills BACKFILL_DAYS;
    # after that each run re-syncs only the last RESYNC_DAYS — "today"
    # keeps changing throughout the day, so the tail is always refreshed.
    # Upsert by [tenant, channel, date] makes any overlap idempotent.
    #
    # Timeline "date" comes as "DD/MM" with NO year (confirmed payload) —
    # the year is inferred from the requested window, which also handles a
    # window spanning a year boundary (Dec→Jan). An entry whose DD/MM can't
    # be placed inside the window is skipped with a warning.
    class MarginSyncService
      BACKFILL_DAYS = 90
      RESYNC_DAYS = 3

      Result = Struct.new(:outcome, :error_message, :metadata, keyword_init: true) do
        def success? = outcome == :success
        def error?   = outcome == :error
      end

      def self.call(channel_credential, days: nil, trigger: "scheduled")
        new(channel_credential, days: days, trigger: trigger).call
      end

      def initialize(channel_credential, days: nil, trigger: "scheduled")
        @channel_credential = channel_credential
        @tenant = channel_credential.tenant
        @days = days
        @trigger = trigger
        @integration = tenant.integrations.active.find_by(provider: "lucrofrete")
        @client = Integrations::LucrofreteClient.new(channel_credential)
        @started_at = Time.current
        @entries_received = 0
        @upserted_count = 0
        @skipped_count = 0
        @skipped_examples = []
      end

      def call
        @log = start_log
        channel = Channel.ensure_for!(tenant, "yampi")
        window_from, window_to = resolve_window(channel)

        entries = client.fetch_timeline(start_date: window_from, end_date: window_to)
        entries = [] unless entries.is_a?(Array)
        @entries_received = entries.size

        entries.each { |entry| upsert_day(entry, channel, window_from, window_to) }

        channel_credential.update!(last_synced_at: Time.current, status: "active")
        finish_log(status: "success", window_from: window_from, window_to: window_to)
        result(:success, nil)
      rescue Integrations::AuthenticationError => e
        channel_credential.update!(status: "error")
        finish_log(status: "error", error_message: e.message)
        result(:error, e.message)
      rescue Integrations::ApiError, Integrations::RateLimitError => e
        finish_log(status: "error", error_message: e.message)
        result(:error, e.message)
      rescue => e
        finish_log(status: "error", error_message: e.message)
        result(:error, e.message)
      end

      private

      attr_reader :channel_credential, :tenant, :trigger, :integration, :client, :started_at, :log

      def resolve_window(channel)
        window_to = Date.current
        days = @days.to_i.positive? ? @days.to_i : default_days(channel)
        [ window_to - (days - 1), window_to ]
      end

      def default_days(channel)
        tenant.freight_margin_dailies.where(channel: channel).exists? ? RESYNC_DAYS : BACKFILL_DAYS
      end

      def upsert_day(entry, channel, window_from, window_to)
        unless entry.is_a?(Hash)
          record_skip(entry, "entrada não é um hash")
          return
        end

        date = resolve_date(entry["date"], window_from, window_to)
        unless date
          record_skip(entry, "date '#{entry['date']}' não resolvível dentro da janela #{window_from}..#{window_to}")
          return
        end

        row = tenant.freight_margin_dailies.find_or_initialize_by(channel: channel, date: date)
        row.assign_attributes(
          order_count:     entry["order_count"].to_i,
          freight_charged: entry["freight_charged"].to_f,
          freight_cost:    entry["freight_cost"].to_f,
          margin_value:    entry["margin_value"].to_f,
          margin_percent:  entry["margin_percent"].present? ? entry["margin_percent"].to_f : nil,
          synced_at:       Time.current
        )
        row.save!
        @upserted_count += 1
      end

      # "DD/MM" → a Date inside [window_from, window_to]. Every year the
      # window touches is tried; ambiguity is impossible for windows under
      # one year (a DD/MM occurs at most once inside them).
      def resolve_date(raw, window_from, window_to)
        match = raw.to_s.strip.match(%r{\A(\d{1,2})/(\d{1,2})\z})
        # Defensivo: se algum dia o endpoint passar a mandar data completa,
        # aceita ISO ("YYYY-MM-DD") sem quebrar.
        return parse_iso_date(raw, window_from, window_to) unless match

        day = match[1].to_i
        month = match[2].to_i

        (window_from.year..window_to.year).each do |year|
          date = Date.new(year, month, day) rescue nil
          return date if date && date.between?(window_from, window_to)
        end

        nil
      end

      def parse_iso_date(raw, window_from, window_to)
        date = Date.parse(raw.to_s)
        date.between?(window_from, window_to) ? date : nil
      rescue ArgumentError, TypeError
        nil
      end

      def record_skip(entry, reason)
        @skipped_count += 1
        @skipped_examples << { entry: entry.is_a?(Hash) ? entry.slice("date") : entry.to_s.first(50), reason: reason } if @skipped_examples.size < 10
        Rails.logger.warn("[Integrations::Lucrofrete::MarginSyncService] entrada ignorada: #{reason}")
      end

      def start_log
        IntegrationSyncLog.create!(
          tenant: tenant,
          integration: integration,
          direction: "inbound",
          action: "lucrofrete_margin_sync",
          status: "pending",
          started_at: started_at,
          metadata: { trigger: trigger, channel: "lucrofrete", channel_credential_id: channel_credential.id }
        )
      end

      def finish_log(status:, error_message: nil, window_from: nil, window_to: nil)
        return unless log

        finished_at = Time.current
        log.update!(
          status: status,
          finished_at: finished_at,
          duration_ms: ((finished_at - started_at) * 1000).round,
          error_message: error_message,
          metadata: log.metadata.merge(count_metadata).merge(
            window_from: window_from&.iso8601,
            window_to: window_to&.iso8601
          )
        )
      end

      def count_metadata
        {
          entries_received: @entries_received,
          upserted_count: @upserted_count,
          skipped_count: @skipped_count,
          skipped_examples: @skipped_examples
        }
      end

      def result(outcome, error_message)
        Result.new(outcome: outcome, error_message: error_message, metadata: count_metadata)
      end
    end
  end
end
