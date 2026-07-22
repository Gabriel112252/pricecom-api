module StockAlerts
  # Decides whether a product's central pool (Product#free_reserve) is low
  # enough to need a StockAlert, edge-triggered: only the transition from
  # "was fine" to "is now at/below min_threshold" creates a new
  # StockReplenishmentExecution — a product that's been below threshold for
  # a while and gets re-evaluated again (another sale, another sync) just
  # refreshes the existing open StockAlert's numbers, it does not spawn a
  # second attempt. See #call for how the crossing is detected without any
  # caller needing to pass in a "previous" value explicitly.
  #
  # IMPORTANT — a consequence of the "conservative pool" model (locked
  # decision, see Product#free_reserve's own comment): a sale only ever
  # DEDUCTS a channel's own stock_qty, and free_reserve = qty_available
  # minus every channel's stock_qty, so a sale mechanically only ever
  # INCREASES free_reserve, never decreases it. A sale can resolve an
  # already-open alert (moving the pool back above min_threshold) but can
  # never, by itself, be the event that first crosses the pool below
  # min_threshold — that only happens from qty_available dropping
  # (Idworks::StockSyncService) or a channel's own stock_qty rising
  # (ProductSyncService pulling a higher number). OrderStockDeductionService
  # still calls this on every deduction regardless, both because it's the
  # cheapest place to catch a recovery (resolving an open alert) and so the
  # per-product row lock it already takes is available if that ever
  # changes.
  #
  # Fase 2 of the stock/alerts migration made this product-level instead of
  # per-channel: StockAlertRule is one row per product (min_threshold/
  # target_level no longer belong to a specific channel). min_threshold is
  # compared against free_reserve (the pool). target_level keeps its old
  # per-channel meaning ("top this channel's stock back up to X") — applied
  # to whichever channel is currently the product's highest-priority one
  # (ChannelProductListing#channel_priority), not a channel fixed on the
  # rule itself. min_threshold and target_level are on two different
  # scales (pool total vs. one channel's target), which is why
  # StockAlertRule doesn't validate target_level > min_threshold.
  #
  # Called from four event-driven places, never a snapshot-scanning sweep:
  # ProductSyncService (right after a listing's stock_qty is written),
  # Idworks::StockSyncService (right after qty_available changes),
  # OrderStockDeductionService (right after an order debits a channel's
  # stock_qty, inside a per-product row lock — see that class for why), and
  # StockAlertsController#confirm indirectly, via
  # StockAlerts::CreateReplenishmentExecution (a human confirming a
  # semi_automatic alert doesn't need a fresh crossing — see that class).
  # A periodic reconciliation job (StockAlerts::ReconcileAlertsJob) also
  # calls this, but only as a safety net — see that job's own comment.
  class EvaluationService
    # TikTok's write endpoint (TiktokAdapter#update_stock) is implemented
    # and used in production paths — verified via git history: its
    # implementation postdates this constant's original "not implemented
    # yet" comment. No channel is currently write-incapable; kept as an
    # empty whitelist point instead of deleted, since a future channel
    # adapter may legitimately land without write support before its
    # #update_stock does.
    AUTOMATION_INCAPABLE_CHANNELS = [].freeze

    Decision = Struct.new(:alert, :execution, keyword_init: true)

    def self.call(product)
      new(product).call
    end

    def initialize(product)
      @product = product
      @tenant  = product.tenant
    end

    # Returns a Decision (alert + execution, either possibly nil), or nil
    # if there's no active rule for this product at all. Never makes an
    # HTTP call itself — execution (if any) is created "pending" and a
    # separate async job (StockAlerts::ExecuteReplenishmentJob) does the
    # actual channel write. Safe to call from inside a DB row lock.
    def call
      rule = tenant.stock_alert_rules.active.find_by(product: product)
      return unless rule

      open_alert_before = tenant.stock_alerts.open.where(product: product).order(created_at: :desc).first
      free_reserve = product.free_reserve

      if free_reserve > rule.min_threshold
        open_alert_before&.update!(status: "resolved", error_message: nil)
        return Decision.new(alert: nil, execution: nil)
      end

      channel, listing = resolve_target
      crossed_below = open_alert_before.nil?

      alert = upsert_alert(rule, free_reserve: free_reserve, channel: channel, listing: listing)

      execution = nil
      if crossed_below && rule.automation_level == "automatic"
        execution = CreateReplenishmentExecution.call(alert)
      end

      Decision.new(alert: alert, execution: execution)
    end

    private

    attr_reader :product, :tenant

    # Lowest channel_priority among this product's own listings — nil (no
    # listing has a priority set yet) is a real, expected state right after
    # Fase 2 ships: the field starts empty for every existing listing,
    # populated manually per product/channel afterwards.
    def resolve_target
      listing = product.channel_product_listings.where.not(channel_priority: nil).order(:channel_priority).first
      [ listing&.channel, listing ]
    end

    def capable?(channel)
      channel.present? && !AUTOMATION_INCAPABLE_CHANNELS.include?(channel)
    end

    def determine_status(rule, channel, listing, replenish_qty)
      return "insufficient_reserve" if listing.nil? || replenish_qty.nil? || replenish_qty <= 0
      return "pending" unless capable?(channel) # degrades to manual — see AUTOMATION_INCAPABLE_CHANNELS

      case rule.automation_level
      when "semi_automatic" then "awaiting_confirmation"
      else "pending" # manual, or automatic (flipped to executed/failed once ExecuteReplenishmentJob finishes)
      end
    end

    # One open alert per tenant/product (channel is informational, not
    # part of the identity): if one already exists (pending/
    # awaiting_confirmation/insufficient_reserve), refresh it in place
    # instead of creating a second row. The underlying numbers
    # (qty_at_trigger = free_reserve, suggested_replenishment_qty) can
    # legitimately change between evaluations while the human/system still
    # hasn't acted on the alert, so overwriting keeps it accurate for
    # whoever eventually confirms it — but see the class comment for why
    # this refresh does NOT by itself spawn a new
    # StockReplenishmentExecution.
    def upsert_alert(rule, free_reserve:, channel:, listing:)
      needed = listing ? rule.target_level.to_d - listing.stock_qty.to_d : nil
      replenish_qty = listing ? [ needed, free_reserve ].min : 0
      status = determine_status(rule, channel, listing, replenish_qty)

      alert = StockAlert.open.where(tenant: tenant, product: product).order(created_at: :desc).first

      attrs = {
        stock_alert_rule: rule,
        channel: channel,
        qty_at_trigger: free_reserve,
        target_level: rule.target_level,
        suggested_replenishment_qty: replenish_qty || 0,
        automation_level_snapshot: rule.automation_level,
        status: status,
        error_message: nil
      }

      if alert
        alert.update!(attrs)
        alert
      else
        StockAlert.create!(attrs.merge(tenant: tenant, product: product))
      end
    end
  end
end
