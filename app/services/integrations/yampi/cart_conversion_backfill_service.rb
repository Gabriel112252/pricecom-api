module Integrations
  module Yampi
    # One-off reconciliation of the cart → order conversion history.
    #
    # Why it exists: mark_cart_converted (UpsertOrder) only runs for orders
    # that flow through the processor, and OrdersPollingService's
    # unchanged_order? short-circuit skips orders already synced and
    # unchanged — so orders ingested BEFORE the cart_token link existed
    # will never flip their Cart to "converted" on their own.
    #
    # Strategy (bulk re-fetch + persisted link):
    #   Phase 1 — page through the Orders API from the oldest abandoned
    #     cart's date (one paginated fetch_orders pull, ~100 orders per
    #     request — NOT one request per order) and persist each payload's
    #     root-level `cart_token` onto the matching existing Order row.
    #     Persisting keeps the link auditable and makes re-runs cheap.
    #   Phase 2 — for each still-abandoned Cart, find an Order on the same
    #     channel whose cart_token matches Cart#token (the exact same match
    #     key UpsertOrder#mark_cart_converted uses, just inverted) and mark
    #     it converted.
    #
    # Idempotent: only "abandoned" carts are candidates, a cart already
    # "converted" is never touched, and re-running phase 1 just rewrites
    # the same cart_token values.
    class CartConversionBackfillService
      DEFAULT_LOOKBACK_DAYS = 90

      Result = Struct.new(
        :outcome, :orders_scanned, :orders_token_updated, :carts_checked,
        :carts_converted, :error_message, keyword_init: true
      ) do
        def success? = outcome == :success
        def error?   = outcome == :error
      end

      def self.call(channel_credential, since: nil)
        new(channel_credential, since: since).call
      end

      def initialize(channel_credential, since: nil)
        @channel_credential = channel_credential
        @tenant             = channel_credential.tenant
        @integration        = @tenant.integrations.active.find_by(provider: "yampi")
        @since              = since
        @orders_scanned = 0
        @orders_token_updated = 0
        @carts_checked = 0
        @carts_converted = 0
      end

      def call
        unless Order.column_names.include?("cart_token")
          return Result.new(
            outcome: :error,
            error_message: "orders.cart_token não existe — rode a migration AddCartTokenToOrders antes deste backfill",
            **counts
          )
        end

        channel = tenant.channels.find_by(platform: "yampi")
        unless channel
          return Result.new(outcome: :error, error_message: "Canal Yampi não encontrado para o tenant #{tenant.slug}", **counts)
        end

        @log = start_log

        backfill_order_tokens(channel)
        convert_matched_carts(channel)

        finish_log(status: "success")
        Result.new(outcome: :success, error_message: nil, **counts)
      rescue AuthenticationError => e
        channel_credential.update!(status: "error")
        finish_log(status: "error", error_message: e.message)
        Result.new(outcome: :error, error_message: e.message, **counts)
      rescue RateLimitError => e
        finish_log(status: "error", error_message: "rate_limited: #{e.message}")
        Result.new(outcome: :error, error_message: e.message, **counts)
      rescue ApiError => e
        finish_log(status: "error", error_message: e.message)
        Result.new(outcome: :error, error_message: e.message, **counts)
      rescue => e
        finish_log(status: "error", error_message: e.message)
        Result.new(outcome: :error, error_message: e.message, **counts)
      end

      private

      attr_reader :channel_credential, :tenant, :integration, :log

      def backfill_order_tokens(channel)
        adapter = Integrations::YampiAdapter.new(channel_credential.credentials)

        adapter.fetch_orders(since: window_start(channel)).each do |raw_order|
          @orders_scanned += 1
          external_id = (raw_order["id"] || raw_order["order_id"])&.to_s
          cart_token  = raw_order["cart_token"].to_s
          next if external_id.blank? || cart_token.blank?

          order = tenant.orders.find_by(channel: channel, external_id: external_id)
          next unless order
          next if order.cart_token == cart_token

          # update_column: só o vínculo, sem re-disparar callbacks de
          # margem/estoque para pedidos históricos que não mudaram.
          order.update_column(:cart_token, cart_token)
          @orders_token_updated += 1
        end
      end

      def convert_matched_carts(channel)
        tenant.carts.abandoned.where(channel: channel).where.not(token: [ nil, "" ]).find_each do |cart|
          @carts_checked += 1
          order = tenant.orders.find_by(channel: channel, cart_token: cart.token)
          next unless order

          cart.mark_converted!(order)
          @carts_converted += 1
        end
      end

      # Orders can only convert carts abandoned before them, so the fetch
      # window starts at the oldest still-abandoned cart (with a small
      # buffer — a cart is created before it's considered abandoned),
      # falling back to the carts backfill horizon.
      def window_start(channel)
        return @since if @since.present?

        oldest = tenant.carts.abandoned.where(channel: channel).minimum(:abandoned_at)
        (oldest || DEFAULT_LOOKBACK_DAYS.days.ago) - 1.day
      end

      def counts
        {
          orders_scanned: @orders_scanned,
          orders_token_updated: @orders_token_updated,
          carts_checked: @carts_checked,
          carts_converted: @carts_converted
        }
      end

      def start_log
        IntegrationSyncLog.create!(
          tenant:      tenant,
          integration: integration,
          direction:   "inbound",
          action:      "yampi_cart_conversion_backfill",
          status:      "pending",
          started_at:  Time.current,
          metadata:    { channel: "yampi", channel_credential_id: channel_credential.id, since: @since&.iso8601 }
        )
      end

      def finish_log(status:, error_message: nil)
        return unless log

        log.update!(
          status:        status,
          finished_at:   Time.current,
          duration_ms:   ((Time.current - log.started_at) * 1000).round,
          error_message: error_message,
          metadata:      log.metadata.merge(counts)
        )
      end
    end
  end
end
