module Integrations
  module Orders
    class UpsertRefund
      Result = Struct.new(:ok, :refund, :order, :error_message, keyword_init: true) do
        def success? = ok
      end

      def self.call(tenant:, normalized:, integration: nil, channel_credential: nil, provider: nil)
        new(
          tenant: tenant,
          normalized: normalized,
          integration: integration,
          channel_credential: channel_credential,
          provider: provider
        ).call
      end

      def initialize(tenant:, normalized:, integration: nil, channel_credential: nil, provider: nil)
        @tenant             = tenant
        @normalized         = normalized
        @integration        = integration
        @channel_credential = channel_credential
        @provider           = provider
      end

      def call
        channel = resolve_channel
        order = find_order(channel)

        unless order
          return Result.new(
            ok:            false,
            refund:        nil,
            order:         nil,
            error_message: "Order not found for external_id: #{@normalized[:external_id]}"
          )
        end

        ActiveRecord::Base.transaction do
          refund = upsert_refund(order)
          update_order(order)
          run_conflict_detection(order)
          Result.new(ok: true, refund: refund, order: order, error_message: nil)
        end
      rescue ActiveRecord::RecordInvalid => e
        Result.new(ok: false, refund: nil, order: nil, error_message: e.message)
      rescue => e
        Result.new(ok: false, refund: nil, order: nil, error_message: e.message)
      end

      private

      def resolve_channel
        if @channel_credential
          return nil unless @channel_credential.tenant_id == @tenant.id
          return nil if @provider.present? && @channel_credential.channel != @provider

          return Channel.ensure_for!(@tenant, @channel_credential.channel)
        end
        return @integration.channel if @integration&.channel
        return @tenant.channels.find_by(platform: @provider) if @provider
        nil
      end

      def find_order(channel)
        return nil unless channel

        if @channel_credential
          return @tenant.orders.find_by(
            channel_credential: @channel_credential,
            external_id: @normalized[:external_id]
          )
        end

        @tenant.orders.find_by(channel: channel, external_id: @normalized[:external_id])
      end

      def resolve_refund_amount
        amount = @normalized[:refund_amount].to_f
        return amount if amount > 0
        # fallback: usar gross_value quando o payload não traz refund_amount explícito
        gross = @normalized[:gross_value].to_f
        gross > 0 ? gross : 0.0
      end

      def upsert_refund(order)
        refund = @tenant.order_refunds.find_or_initialize_by(
          order:       order,
          external_id: @normalized[:external_id]
        )
        refund.assign_attributes(
          integration: @integration,
          amount:      resolve_refund_amount,
          reason:      @normalized[:refund_reason],
          status:      @normalized[:status].presence || "processed",
          refunded_at: @normalized[:ordered_at] || Time.current,
          metadata:    (refund.metadata || {}).merge(@normalized[:metadata].to_h).merge(
            "order_number"          => @normalized[:order_number],
            "provider"              => @provider,
            "channel_credential_id" => @channel_credential&.id,
            "connection_name"       => @channel_credential&.display_name
          ).compact
        )
        refund.save!
        refund
      end

      def update_order(order)
        total_refunded = @tenant.order_refunds.where(order: order).sum(:amount)
        new_status     = total_refunded > 0 ? "refunded" : order.status

        order.update_columns(
          order_type:    "refund",
          refund_amount: total_refunded,
          status:        new_status
        )
      end

      def run_conflict_detection(order)
        Audits::DetectOrderConflicts.call(order)
      rescue => e
        Rails.logger.error("[Integrations::Orders::UpsertRefund] Audits::DetectOrderConflicts failed for order_id=#{order.id}: #{e.message}")
      end
    end
  end
end
