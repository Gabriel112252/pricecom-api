module Integrations
  module Normalizers
    # Normalizes one entry of TikTok Shop's Search Returns 202309 response
    # (return_refund/202309/returns/search — see TiktokAdapter#fetch_returns)
    # into the shape Integrations::Orders::UpsertRefund expects.
    #
    # Field shape NOT confirmed against partner.tiktokshop.com/docv2 directly
    # (JS-rendered SPA, couldn't be fetched) — reconstructed from the
    # open-source SDK github.com/hsib19/tiktok-shop-sdk
    # (packages/sdk/src/types/ReturnRefundModule.ts). Validate against a real
    # sandbox return before trusting this in production.
    class TiktokReturnRefundNormalizer
      # Doc enum (per the reference SDK): RETURN_OR_REFUND_REQUEST_PENDING /
      # _REJECT / _SUCCESS / _CANCEL / _COMPLETE, AWAITING_BUYER_SHIP,
      # BUYER_SHIPPED_ITEM, REJECT_RECEIVE_PACKAGE, AWAITING_BUYER_RESPONSE —
      # mapped onto OrderRefund::STATUSES (pending/processed/ignored/error).
      PROCESSED_STATUSES = %w[RETURN_OR_REFUND_REQUEST_SUCCESS RETURN_OR_REFUND_REQUEST_COMPLETE].freeze
      IGNORED_STATUSES = %w[RETURN_OR_REFUND_REQUEST_REJECT RETURN_OR_REFUND_REQUEST_CANCEL].freeze

      def self.call(raw)
        new(raw).normalize
      end

      def initialize(raw)
        @r = raw.is_a?(Hash) ? raw : {}
      end

      def normalize
        {
          external_id:   @r["order_id"]&.to_s,
          refund_amount: extract_refund_amount,
          refund_reason: extract_reason,
          status:        extract_status,
          ordered_at:    parse_time(@r["create_time"]),
          metadata: {
            "return_id"                    => @r["return_id"],
            "return_type"                  => @r["return_type"],
            "return_status"                => @r["return_status"],
            "seller_proposed_return_type"  => @r["seller_proposed_return_type"],
            "source"                       => "tiktok_return_refund_api",
            "raw"                          => @r
          }
        }
      end

      private

      # refund_amount.refund_total covers a full REFUND/RETURN_AND_REFUND;
      # partial_refund.amount is the seller_proposed_return_type ==
      # "PARTIAL_REFUND" shape, which doesn't populate refund_amount at all
      # per the reference SDK.
      def extract_refund_amount
        amount = @r.dig("refund_amount", "refund_total")
        amount = @r.dig("partial_refund", "amount") if amount.blank?
        to_f(amount)
      end

      def extract_reason
        @r["return_reason_text"].presence || @r["return_reason"].presence
      end

      def extract_status
        raw_status = @r["return_status"].to_s
        return "processed" if PROCESSED_STATUSES.include?(raw_status)
        return "ignored" if IGNORED_STATUSES.include?(raw_status)

        "pending"
      end

      def to_f(val)
        return 0.0 if val.nil?

        val.to_s.gsub(",", ".").to_f
      end

      def parse_time(val)
        return nil if val.blank?
        return Time.zone.at(val.to_i) if val.to_s.match?(/\A\d{10,13}\z/)

        Time.zone.parse(val.to_s)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
