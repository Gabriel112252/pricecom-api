module StockAlerts
  # Decides whether a just-synced ChannelProductListing is low enough to
  # need a StockAlert, and — depending on the tenant's StockAlertRule for
  # that product/channel — whether to just notify (manual), wait for a
  # human (semi_automatic), or replenish right away
  # (automatic, via ReplenishmentExecutorService).
  #
  # Called from two places: ProductSyncService (right after a listing's
  # stock_qty is written — the natural moment stock just changed on a
  # channel) and Idworks::StockSyncService (via
  # .reevaluate_insufficient_reserves, when a product's total qty_available
  # changes — the free reserve every channel draws from may have changed
  # too, so an old insufficient_reserve alert might now be fulfillable).
  class EvaluationService
    # TikTok's adapter#update_stock isn't implemented yet (unconfirmed
    # write endpoint — see TiktokAdapter#update_stock). Any rule on this
    # channel behaves as if automation_level were "manual", regardless of
    # what's actually configured — a notification-only alert is still
    # useful even where auto-execution isn't possible yet.
    AUTOMATION_INCAPABLE_CHANNELS = %w[tiktok].freeze

    def self.call(listing)
      new(listing).call
    end

    # Re-runs the evaluation for every channel where this product currently
    # has an open "insufficient_reserve" alert — meant to be called right
    # after a product's qty_available changes (Idworks::StockSyncService).
    # Deliberately simple: just re-checks each affected channel's current
    # listing, reusing #call's normal upsert-in-place logic to
    # promote/refresh/resolve the existing alert. No batching/backoff.
    def self.reevaluate_insufficient_reserves(product)
      channels = StockAlert.where(product: product, status: "insufficient_reserve").distinct.pluck(:channel)

      channels.each do |channel|
        listing = ChannelProductListing.find_by(product: product, channel: channel)
        call(listing) if listing
      end
    end

    def initialize(listing)
      @listing = listing
      @tenant  = listing.tenant
      @product = listing.product
      @channel = listing.channel
    end

    def call
      rule = tenant.stock_alert_rules.active.find_by(product: product, channel: channel)
      return unless rule # no rule configured — no default, no alert

      return if listing.stock_qty.to_d > rule.min_threshold.to_d

      needed = rule.target_level.to_d - listing.stock_qty.to_d
      replenish_qty = [ needed, product.free_reserve ].min

      if replenish_qty <= 0
        upsert_alert(rule, replenish_qty, "insufficient_reserve")
        return
      end

      alert = upsert_alert(rule, replenish_qty, initial_status_for(rule))
      ReplenishmentExecutorService.call(alert) if auto_execute?(rule)
    end

    private

    attr_reader :listing, :tenant, :product, :channel

    def capable?
      !AUTOMATION_INCAPABLE_CHANNELS.include?(channel)
    end

    def auto_execute?(rule)
      rule.automation_level == "automatic" && capable?
    end

    def initial_status_for(rule)
      return "pending" unless capable? # degrades to manual — see AUTOMATION_INCAPABLE_CHANNELS

      case rule.automation_level
      when "semi_automatic" then "awaiting_confirmation"
      else "pending" # manual, or automatic (flipped to executed/failed right after by #call)
      end
    end

    # One open alert per tenant/product/channel: if one already exists
    # (pending/awaiting_confirmation/insufficient_reserve), refresh it in
    # place instead of creating a second row. The underlying numbers
    # (qty_at_trigger, free reserve) can legitimately change between polls
    # while the human/system still hasn't acted on the alert, so
    # overwriting keeps suggested_replenishment_qty accurate for whoever
    # eventually confirms it — a plain "ignore if one exists" would leave a
    # stale suggested quantity sitting there. See StockAlert::STATUSES for
    # why this means #skipped_duplicate is never actually produced here.
    def upsert_alert(rule, replenish_qty, status)
      alert = StockAlert.open.where(tenant: tenant, product: product, channel: channel).order(created_at: :desc).first

      attrs = {
        stock_alert_rule: rule,
        qty_at_trigger: listing.stock_qty,
        target_level: rule.target_level,
        suggested_replenishment_qty: replenish_qty,
        automation_level_snapshot: rule.automation_level,
        status: status,
        error_message: nil
      }

      if alert
        alert.update!(attrs)
        alert
      else
        StockAlert.create!(attrs.merge(tenant: tenant, product: product, channel: channel))
      end
    end
  end
end
