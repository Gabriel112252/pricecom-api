module Integrations
  module Yampi
    # One-off pull of Yampi orders created in the last N days — the webhook
    # only fires for orders placed after it was registered, so history from
    # before that point needs to be pulled explicitly via the Orders API.
    #
    # Mirrors ProductSyncService's shape (IntegrationSyncLog bookkeeping,
    # AuthenticationError/RateLimitError/ApiError handling) but funnels every
    # order through the exact same Integrations::Processors::YampiOrderProcessor
    # the webhook uses, so there's exactly one place that decides
    # order-vs-refund and does the upsert — see YampiOrderProcessor and
    # Integrations::Orders::UpsertOrder. Idempotent via Order#external_id:
    # an order already created by the webhook (or a previous backfill run)
    # is updated in place, never duplicated, and OrderStockDeductionService's
    # own stock_deducted_at guard (reused unchanged) prevents a double
    # stock debit for whichever of the two ran first.
    #
    # Persistence is INCREMENTAL, one PAGE at a time, not "fetch every page
    # for the whole window, then persist everything at the end" — a run
    # against a wide window can legitimately take minutes (throttled at
    # YampiAdapter::ORDERS_PAGE_SLEEP_SECONDS per page), and a failure
    # partway through (network blip, a 429 that escapes the throttle, an
    # unhandled edge case) used to discard every order already fetched,
    # forcing a full restart. Orders are upserted as soon as their page
    # arrives (via YampiAdapter#fetch_orders's per-page block), so a
    # failure on page N never loses pages before it.
    #
    # Progress — including the fetch window itself — is tracked on an
    # IntegrationSyncLog (action: "order_backfill"), the same mechanism
    # Integrations::Tiktok::DiscountBackfillService uses for the same class
    # of problem. A "pending" log from a previous run is resumed from its
    # last_completed_page, requesting `start_page:` on the adapter so
    # already-fetched pages aren't re-requested. The window itself
    # (window_start/window_end) is READ BACK from that log rather than
    # recomputed from `days:` — `days.days.ago` is relative to "now", so
    # recomputing it on a resume hours or days later would silently shift
    # the date range, making "page N" mean something different than it did
    # on the original attempt. A brand new run still computes it fresh.
    #
    # No attempt is made to resume PAST a bisection split (see
    # YampiAdapter::ORDERS_PAGINATION_LIMIT_ERROR) — that's a rare edge
    # case on top of an already-rare edge case, and falling back to
    # re-fetching that one page range from its start is safe (idempotent
    # upsert), just not maximally efficient.
    class BackfillOrdersService
      DEFAULT_DAYS = 30
      ACTION = "order_backfill"

      # Stand-in for an IntegrationEvent: YampiOrderProcessor and
      # YampiOrderNormalizer only ever read #tenant, #payload, #event_type
      # and #integration off whatever they're given, so a persisted
      # IntegrationEvent (and the async ProcessEventJob machinery built for
      # webhook delivery) isn't needed for this synchronous, admin-triggered
      # pull.
      BackfillEvent = Struct.new(:tenant, :payload, :event_type, :integration, keyword_init: true)

      Result = Struct.new(:outcome, :created_count, :updated_count, :skipped, :error_message, keyword_init: true) do
        def success? = outcome == :success
        def error?   = outcome == :error
      end

      def self.call(channel_credential, days: DEFAULT_DAYS)
        new(channel_credential, days: days).call
      end

      def initialize(channel_credential, days: DEFAULT_DAYS)
        @channel_credential = channel_credential
        @tenant             = channel_credential.tenant
        @days               = days.to_i.positive? ? days.to_i : DEFAULT_DAYS
        @integration        = @tenant.integrations.active.find_by(provider: "yampi")
        @created  = 0
        @updated  = 0
        @skipped  = []
        @seen_external_ids = Set.new
      end

      def call
        @log = resume_or_start_log
        adapter = Integrations::YampiAdapter.new(channel_credential.credentials)
        adapter.authenticate

        adapter.fetch_orders(since: window_start, until_date: window_end, start_page: resume_from_page) do |page_orders, page|
          process_orders(page_orders)
          persist_progress(last_completed_page: page)
        end

        finish_log(status: "success")
        Result.new(outcome: :success, created_count: created, updated_count: updated, skipped: skipped, error_message: nil)
      rescue AuthenticationError => e
        channel_credential.update!(status: "error")
        finish_log(status: "error", error_message: e.message)
        Result.new(outcome: :error, created_count: created, updated_count: updated, skipped: skipped, error_message: e.message)
      rescue RateLimitError, ApiError => e
        # Deliberately does NOT call finish_log — the log stays "pending"
        # with last_completed_page already reflecting every page persisted
        # before this one, so the next invocation resumes from there
        # instead of re-fetching the whole window from page 1.
        persist_progress(error_message: e.message)
        Result.new(outcome: :error, created_count: created, updated_count: updated, skipped: skipped, error_message: e.message)
      end

      private

      attr_reader :channel_credential, :tenant, :days, :integration, :created, :updated, :skipped, :log,
        :window_start, :window_end, :resume_from_page

      def process_orders(raw_orders)
        raw_orders.each do |raw_order|
          external_id = (raw_order["id"] || raw_order["order_id"])&.to_s

          if external_id.blank?
            @skipped << { external_id: nil, reason: "sem identificador externo" }
            next
          end

          # Guards against a page-boundary overlap returning the same order
          # twice within one run — a real duplicate, not just "already
          # existed from a previous run" (that case is a normal update).
          # Instance-level (not reset per page) so it still catches
          # overlaps across the whole run, now that pages are processed as
          # they arrive instead of all at once at the end.
          if @seen_external_ids.include?(external_id)
            @skipped << { external_id: external_id, reason: "duplicado na mesma importação" }
            next
          end
          @seen_external_ids << external_id

          process_order(raw_order, external_id)
        end
      end

      def process_order(raw_order, external_id)
        already_existed = tenant.orders.exists?(external_id: external_id)

        event  = BackfillEvent.new(tenant: tenant, payload: raw_order, event_type: "order.backfill", integration: integration)
        result = Integrations::Processors::YampiOrderProcessor.call(event)

        if result.outcome == :success
          already_existed ? (@updated += 1) : (@created += 1)
        else
          @skipped << { external_id: external_id, reason: result.error_message || "erro desconhecido" }
        end
      end

      def resume_or_start_log
        existing = IntegrationSyncLog
          .where(tenant: tenant, integration: integration, action: ACTION, status: "pending")
          .order(created_at: :desc)
          .first

        if existing
          meta = existing.metadata
          @created           = meta["created_count"].to_i
          @updated           = meta["updated_count"].to_i
          @skipped           = meta["skipped"] || []
          @resume_from_page  = meta["last_completed_page"].to_i + 1
          @window_start      = Date.parse(meta["window_start"])
          @window_end        = Date.parse(meta["window_end"])
          existing
        else
          @resume_from_page = 1
          @window_start     = days.days.ago.to_date
          @window_end       = Time.current.to_date
          IntegrationSyncLog.create!(
            tenant: tenant, integration: integration, direction: "inbound", action: ACTION,
            status: "pending", started_at: Time.current,
            metadata: {
              channel: "yampi", channel_credential_id: channel_credential.id, days: days,
              window_start: window_start.iso8601, window_end: window_end.iso8601
            }
          )
        end
      end

      def persist_progress(last_completed_page: nil, error_message: nil)
        meta = log.metadata.merge(
          created_count: created,
          updated_count: updated,
          skipped_count: skipped.size,
          skipped: skipped.first(20)
        )
        meta["last_completed_page"] = last_completed_page if last_completed_page
        meta["last_error"] = error_message if error_message
        log.update!(metadata: meta)
      end

      def finish_log(status:, error_message: nil)
        log.update!(
          status:        status,
          finished_at:   Time.current,
          duration_ms:   ((Time.current - log.started_at) * 1000).round,
          error_message: error_message,
          metadata:      log.metadata.merge(
            created_count: created,
            updated_count: updated,
            skipped_count: skipped.size,
            skipped:       skipped.first(20)
          )
        )
      end
    end
  end
end
