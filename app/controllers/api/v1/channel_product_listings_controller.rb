module Api
  module V1
    # Writes an absolute stock quantity to one real sales channel. The
    # remote write happens before the local listing is changed, so a channel
    # rejection cannot leave the overview pretending the value was updated.
    class ChannelProductListingsController < ApplicationController
      before_action :require_admin!, only: [ :update ]

      # PATCH /api/v1/channel_product_listings/:id
      def update
        listing = current_tenant.channel_product_listings.find(params[:id])
        quantity = parsed_quantity

        return render json: { error: "quantity deve ser um número maior ou igual a zero" },
          status: :unprocessable_entity unless quantity

        log = start_manual_write_log(listing, quantity)

        begin
          StockAlerts::ReplenishmentExecutorService.write_stock(listing, quantity)
          listing.update!(stock_qty: quantity)
          finish_manual_write_log(log, status: "success")

          render json: listing_json(listing)
        rescue Integrations::AuthenticationError, Integrations::RateLimitError,
               Integrations::ApiError, Integrations::UnsupportedOperationError,
               ArgumentError, NotImplementedError => e
          finish_manual_write_log(log, status: "error", error_message: e.message)
          render json: { error: e.message }, status: :unprocessable_entity
        end
      end

      private

      def parsed_quantity
        raw = manual_stock_params[:quantity]
        return if raw.blank?

        value = BigDecimal(raw.to_s)
        value if value.finite? && value >= 0
      rescue ArgumentError
        nil
      end

      def manual_stock_params
        params.permit(:quantity)
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
          updated_at: listing.updated_at
        }
      end
    end
  end
end
