module StockAlerts
  # Creates one StockReplenishmentExecution for an alert's already-resolved
  # target channel (StockAlert#channel, set by EvaluationService from
  # ChannelProductListing#channel_priority) — used both by EvaluationService
  # (automatic rules, right after a threshold crossing) and
  # StockAlertsController#confirm (semi_automatic rules, once a human
  # confirms). Never calls the channel's API itself — creates the row and
  # enqueues StockAlerts::ExecuteReplenishmentJob, which does that async, so
  # neither caller (one holding a product row lock, the other inside an
  # HTTP request) blocks on a live remote write.
  #
  # If the channel isn't currently replenishment_eligible, still creates
  # the row (status "skipped") instead of silently doing nothing — Fase 4's
  # history view needs "ignored by ineligibility" to be a real, visible
  # outcome, not an absence of one.
  #
  # A failed/skipped execution does NOT get silently retried by a later
  # evaluation of the same still-open alert — EvaluationService only calls
  # this on a fresh threshold crossing (see its own comment), not on every
  # subsequent evaluation while still below. Retrying an existing alert's
  # attempt only happens via an explicit action (a human re-confirming) —
  # deliberate, to avoid silent retry storms against a channel that just
  # rejected a write.
  class CreateReplenishmentExecution
    def self.call(alert)
      new(alert).call
    end

    def initialize(alert)
      @alert   = alert
      @tenant  = alert.tenant
      @product = alert.product
      @rule    = alert.stock_alert_rule
    end

    def call
      return unless rule
      return unless channel.present? && listing.present?
      return if StockReplenishmentExecution.exists?(channel_product_listing: listing, stock_alert_rule: rule, status: StockReplenishmentExecution::IN_FLIGHT_STATUSES)

      requested_qty = [ rule.target_level.to_d - listing.stock_qty.to_d, product.free_reserve ].min
      return if requested_qty <= 0

      execution = build_execution(requested_qty)
      StockAlerts::ExecuteReplenishmentJob.perform_later(execution.id) if execution.status == "pending"
      execution
    end

    private

    attr_reader :alert, :tenant, :product, :rule

    def channel
      @channel ||= alert.channel
    end

    def listing
      @listing ||= channel && tenant.channel_product_listings.find_by(product: product, channel: channel)
    end

    def build_execution(requested_qty)
      eligible = listing.replenishment_eligible?

      StockReplenishmentExecution.create!(
        tenant: tenant,
        product: product,
        channel_product_listing: listing,
        stock_alert_rule: rule,
        stock_alert: alert,
        trigger_type: "minimum_threshold_reached",
        status: eligible ? "pending" : "skipped",
        threshold_qty: rule.min_threshold,
        target_qty: rule.target_level,
        previous_qty: listing.stock_qty,
        requested_qty: requested_qty,
        remote_status_snapshot: {
          remote_status: listing.remote_status,
          selling_status: listing.selling_status,
          replenishment_eligible: listing.replenishment_eligible,
          remote_status_synced_at: listing.remote_status_synced_at
        },
        rule_snapshot: {
          min_threshold: rule.min_threshold,
          target_level: rule.target_level,
          automation_level: rule.automation_level
        },
        # Includes an attempt number, not just the alert id: a "skipped"
        # execution (ineligible at creation time) must be retriable later
        # (e.g. by a human reconfirming, or a future reconciliation pass)
        # without colliding on the unique idempotency_key — the in-flight
        # partial unique index (see the migration) is what actually
        # prevents concurrent duplicates, this just prevents the exact
        # same attempt being recorded twice.
        idempotency_key: "alert-#{alert.id}-attempt-#{StockReplenishmentExecution.where(stock_alert: alert).count + 1}",
        error_message: eligible ? nil : "canal #{channel} não elegível para abastecimento (selling_status=#{listing.selling_status})"
      )
    end
  end
end
