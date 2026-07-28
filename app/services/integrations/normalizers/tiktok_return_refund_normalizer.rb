module Integrations
  module Normalizers
    # Normalizes one entry of TikTok Shop's Search Returns 202309 response
    # (return_refund/202309/returns/search — see TiktokAdapter#fetch_returns)
    # into the shape Integrations::Orders::UpsertRefund expects.
    #
    # Shape CONFIRMED via a real production call (tenant Hidrabene,
    # 2026-07-28) — see spec/fixtures/integrations/tiktok_returns.json for
    # the verbatim response. This replaces an earlier version of this class
    # that was built from a third-party SDK's guessed field names
    # (github.com/hsib19/tiktok-shop-sdk); notably, that SDK's
    # `partial_refund` field does NOT appear anywhere in the real payload —
    # refund_amount.refund_total is the only amount field, full stop.
    #
    # return_status: only RETURN_OR_REFUND_REQUEST_PENDING and
    # BUYER_SHIPPED_ITEM have been observed in production so far, and both
    # are in-flight (not resolved). No terminal value (approved/rejected/
    # completed/cancelled) has been confirmed yet — the third-party SDK did
    # guess strings for those (…_SUCCESS/_COMPLETE/_REJECT/_CANCEL), but
    # trusting an unconfirmed guess risks mis-classifying a still-open
    # return as processed/ignored. extract_status below deliberately maps
    # EVERY return_status — known or not — to "pending" until a return
    # actually resolves in production and reveals the real terminal string;
    # see ReturnRefundSyncSchedulerJob, deliberately not wired into
    # config/schedule.yml yet for the same reason.
    class TiktokReturnRefundNormalizer
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
            "return_id"     => @r["return_id"],
            "return_type"   => @r["return_type"],
            "return_status" => @r["return_status"],
            "return_reason" => @r["return_reason"],
            "update_time"   => @r["update_time"],
            "source"        => "tiktok_return_refund_api",
            "raw"           => @r
          }
        }
      end

      private

      def extract_refund_amount
        to_f(@r.dig("refund_amount", "refund_total"))
      end

      def extract_reason
        @r["return_reason_text"].presence || @r["return_reason"].presence
      end

      def extract_status
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
