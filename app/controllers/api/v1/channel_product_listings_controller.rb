module Api
  module V1
    # Writes an absolute stock quantity to one real sales channel. The
    # remote write happens before the local listing is changed, so a channel
    # rejection cannot leave the overview pretending the value was updated.
    class ChannelProductListingsController < ApplicationController
      before_action :require_admin!, only: [ :update, :channel_action ]

      # Fase 4 modal actions — per channel, exactly the set the UI is
      # allowed to offer (see StockProductDetailModal.vue): Shopify's
      # status/publish are independent knobs (5 actions), TikTok only ever
      # exposes activate/deactivate (see TiktokAdapter#normalize_selling_status
      # for why the platform-controlled statuses aren't editable targets),
      # Yampi separates product-level activation from SKU-level sale
      # blocking.
      CHANNEL_ACTIONS = {
        "shopify" => %w[activate draft archive publish unpublish],
        "tiktok"  => %w[activate deactivate],
        "yampi"   => %w[activate_product deactivate_product block_sale unblock_sale]
      }.freeze

      # PATCH /api/v1/channel_product_listings/:id
      def update
        listing = current_tenant.channel_product_listings.find(params[:id])

        if manual_stock_params.key?(:channel_priority)
          return update_channel_priority(listing)
        end

        quantity = parsed_quantity

        return render json: { error: "quantity deve ser um número maior ou igual a zero" },
          status: :unprocessable_entity unless quantity

        log = start_manual_write_log(listing, quantity)
        previous_stock_qty = listing.stock_qty

        begin
          StockAlerts::ReplenishmentExecutorService.write_stock(listing, quantity)
          listing.update!(stock_qty: quantity)
          record_channel_movement(listing, previous_stock_qty)
          finish_manual_write_log(log, status: "success")

          render json: listing_json(listing)
        rescue Integrations::AuthenticationError, Integrations::RateLimitError,
               Integrations::ApiError, Integrations::UnsupportedOperationError,
               ArgumentError, NotImplementedError => e
          finish_manual_write_log(log, status: "error", error_message: e.message)
          render json: { error: e.message }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/channel_product_listings/:id/channel_action
      #
      # Writes the real channel status via the adapter, then updates the
      # local snapshot fields optimistically by re-running the SAME
      # adapter#normalize_selling_status mapping the sync flow uses (fed a
      # synthetic raw hash reflecting just the one thing this action
      # changed) — one status→field mapping table per channel, not two.
      # The next scheduled sync (≤15min) reconciles with whatever the
      # channel actually reports either way.
      def channel_action
        listing = current_tenant.channel_product_listings.find(params[:id])
        action_name = params[:channel_action_name].to_s

        allowed = CHANNEL_ACTIONS[listing.channel] || []
        unless allowed.include?(action_name)
          return render json: { error: "ação '#{action_name}' não permitida para o canal #{listing.channel}" },
            status: :unprocessable_entity
        end

        credential = current_tenant.channel_credentials.find_by(channel: listing.channel)
        unless credential
          return render json: { error: "nenhuma credencial conectada para o canal #{listing.channel}" },
            status: :unprocessable_entity
        end

        begin
          adapter = Integrations::ProductSyncService.adapter_for(credential)
          apply_channel_action!(adapter, listing, action_name)
          render json: listing_json(listing.reload)
        rescue Integrations::AuthenticationError, Integrations::RateLimitError,
               Integrations::ApiError, Integrations::UnsupportedOperationError,
               ArgumentError, NotImplementedError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end
      end

      private

      def update_channel_priority(listing)
        raw = manual_stock_params[:channel_priority]
        value = raw.blank? ? nil : Integer(raw, exception: false)

        if raw.present? && (value.nil? || value <= 0)
          return render json: { error: "channel_priority deve ser um inteiro maior que zero (ou vazio, pra remover a prioridade)" },
            status: :unprocessable_entity
        end

        listing.update!(channel_priority: value)
        render json: listing_json(listing)
      end

      def apply_channel_action!(adapter, listing, action_name)
        case [ listing.channel, action_name ]
        in [ "shopify", "activate" ]
          require_external_product_id!(listing)
          adapter.update_selling_status(product_id: listing.external_product_id, status: "active")
          apply_selling_status!(adapter, listing, "_product_status" => "active", "_product_published_at" => listing.remote_status_metadata["published_at"])
        in [ "shopify", "draft" ]
          require_external_product_id!(listing)
          adapter.update_selling_status(product_id: listing.external_product_id, status: "draft")
          apply_selling_status!(adapter, listing, "_product_status" => "draft", "_product_published_at" => listing.remote_status_metadata["published_at"])
        in [ "shopify", "archive" ]
          require_external_product_id!(listing)
          adapter.update_selling_status(product_id: listing.external_product_id, status: "archived")
          apply_selling_status!(adapter, listing, "_product_status" => "archived", "_product_published_at" => listing.remote_status_metadata["published_at"])
        in [ "shopify", "publish" ]
          require_external_product_id!(listing)
          adapter.update_selling_status(product_id: listing.external_product_id, published: true)
          apply_selling_status!(adapter, listing, "_product_status" => listing.remote_status, "_product_published_at" => Time.now.utc.iso8601)
        in [ "shopify", "unpublish" ]
          require_external_product_id!(listing)
          adapter.update_selling_status(product_id: listing.external_product_id, published: false)
          apply_selling_status!(adapter, listing, "_product_status" => listing.remote_status, "_product_published_at" => nil)
        in [ "tiktok", "activate" ]
          require_external_product_id!(listing)
          adapter.activate_product(product_id: listing.external_product_id)
          apply_selling_status!(adapter, listing, "_product_status" => "ACTIVATE")
        in [ "tiktok", "deactivate" ]
          require_external_product_id!(listing)
          adapter.deactivate_product(product_id: listing.external_product_id)
          apply_selling_status!(adapter, listing, "_product_status" => "SELLER_DEACTIVATED")
        in [ "yampi", "activate_product" ]
          require_external_product_id!(listing)
          adapter.update_product_active(product_id: listing.external_product_id, active: true)
          apply_selling_status!(adapter, listing, "_product_active" => true, "blocked_sale" => listing.remote_status_metadata["blocked_sale"])
        in [ "yampi", "deactivate_product" ]
          require_external_product_id!(listing)
          adapter.update_product_active(product_id: listing.external_product_id, active: false)
          apply_selling_status!(adapter, listing, "_product_active" => false, "blocked_sale" => listing.remote_status_metadata["blocked_sale"])
        in [ "yampi", "block_sale" ]
          adapter.update_sku_blocked_sale(sku_id: listing.external_id, blocked: true)
          apply_selling_status!(adapter, listing, "_product_active" => listing.remote_status_metadata["product_active"], "blocked_sale" => true)
        in [ "yampi", "unblock_sale" ]
          adapter.update_sku_blocked_sale(sku_id: listing.external_id, blocked: false)
          apply_selling_status!(adapter, listing, "_product_active" => listing.remote_status_metadata["product_active"], "blocked_sale" => false)
        end
      end

      def require_external_product_id!(listing)
        return if listing.external_product_id.present?

        raise ArgumentError, "listing sem external_product_id — rode um sync antes de tentar mudar o status"
      end

      def apply_selling_status!(adapter, listing, raw)
        normalized = adapter.normalize_selling_status(raw)
        listing.update!(
          remote_status: normalized[:remote_status],
          remote_status_reason: normalized[:remote_status_reason],
          remote_status_metadata: normalized[:remote_status_metadata],
          remote_status_synced_at: Time.current,
          selling_status: normalized[:selling_status],
          selling_enabled: normalized[:selling_enabled],
          replenishment_eligible: normalized[:replenishment_eligible]
        )
      end

      def record_channel_movement(listing, previous_stock_qty)
        StockMovement.record!(
          tenant: current_tenant,
          product: listing.product,
          channel: listing.channel,
          kind: "ajuste",
          previous_qty: previous_stock_qty || 0,
          new_qty: listing.stock_qty,
          source: "manual_channel_adjust",
          user: current_user
        )
      rescue => e
        Rails.logger.error("[StockMovement] manual channel adjust log failed for listing=#{listing.id}: #{e.message}")
      end

      def parsed_quantity
        raw = manual_stock_params[:quantity]
        return if raw.blank?

        value = BigDecimal(raw.to_s)
        value if value.finite? && value >= 0
      rescue ArgumentError
        nil
      end

      def manual_stock_params
        params.permit(:quantity, :channel_priority)
      end

      def start_manual_write_log(listing, quantity)
        current_tenant.integration_sync_logs.create!(
          direction: "outbound",
          action: "manual_stock_update",
          status: "pending",
          external_id: listing.external_id,
          external_type: "ChannelProductListing",
          request_payload: {
            listing_id: listing.id,
            product_id: listing.product_id,
            channel: listing.channel,
            quantity: quantity.to_s("F"),
            previous_stock_qty: listing.stock_qty&.to_s,
            user_id: current_user.id
          },
          metadata: {
            source: "stock_overview_manual_edit",
            listing_id: listing.id,
            product_id: listing.product_id,
            channel: listing.channel,
            user_id: current_user.id,
            user_email: current_user.email
          },
          started_at: Time.current
        )
      end

      def finish_manual_write_log(log, status:, error_message: nil)
        finished_at = Time.current
        log.update!(
          status: status,
          error_message: error_message,
          finished_at: finished_at,
          duration_ms: ((finished_at - log.started_at) * 1000).round
        )
      end

      def listing_json(listing)
        {
          id: listing.id,
          product_id: listing.product_id,
          channel: listing.channel,
          external_id: listing.external_id,
          external_sku: listing.external_sku,
          stock_qty: listing.stock_qty,
          external_inventory_item_id: listing.external_inventory_item_id,
          external_product_id: listing.external_product_id,
          channel_priority: listing.channel_priority,
          remote_status: listing.remote_status,
          remote_status_reason: listing.remote_status_reason,
          remote_status_synced_at: listing.remote_status_synced_at,
          status_stale: listing.status_stale?,
          selling_status: listing.selling_status,
          selling_enabled: listing.selling_enabled,
          replenishment_eligible: listing.replenishment_eligible,
          updated_at: listing.updated_at
        }
      end
    end
  end
end
