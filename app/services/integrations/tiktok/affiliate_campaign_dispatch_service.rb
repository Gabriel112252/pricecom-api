module Integrations
  module Tiktok
    # Dispatches one AffiliateCampaign: materializes AffiliateCampaignRecipient
    # rows from the campaign's segment_filter (idempotent — unique index on
    # [affiliate_campaign_id, affiliate_creator_id]), then sends the
    # message_template to every still-pending recipient with a preventive
    # sleep between sends.
    #
    # Rate-limit handling mirrors PendingFinancialSyncService, not
    # AffiliateSyncService/FinancialBackfillService: here there IS a queue
    # of pending domain rows (AffiliateCampaignRecipient), so a rate limit
    # leaves the affected recipient "pending" (not "failed") and stops the
    # batch WITHOUT raising — AffiliateCampaignDispatchJob reschedules the
    # continuation from next_retry_at instead of relying on ActiveJob's
    # generic retry_on.
    class AffiliateCampaignDispatchService
      DEFAULT_SLEEP_SECONDS = Integer(ENV.fetch("TIKTOK_AFFILIATE_CAMPAIGN_SLEEP_MS", "250")) / 1000.0
      RECENT_BASE_DELAY = 5.minutes

      Result = Struct.new(:outcome, :next_retry_at, keyword_init: true) do
        def success? = outcome == :success
      end

      def self.call(campaign, sleep_seconds: DEFAULT_SLEEP_SECONDS)
        new(campaign, sleep_seconds: sleep_seconds).call
      end

      def initialize(campaign, sleep_seconds:)
        @campaign = campaign
        @tenant = campaign.tenant
        @sleep_seconds = sleep_seconds.to_f.positive? ? sleep_seconds.to_f : 0
        @rate_limit_hit = false
        @next_retry_at = nil
      end

      def call
        ensure_recipients!
        campaign.update!(status: "sending") if campaign.status == "draft"

        pending_recipients.find_each do |recipient|
          process_recipient(recipient)
          break if rate_limit_hit?
          sleep(sleep_seconds) if sleep_seconds.positive?
        end

        refresh_counts!
        campaign.update!(status: "completed") unless rate_limit_hit? || pending_recipients.exists?
        Result.new(outcome: :success, next_retry_at: next_retry_at)
      end

      private

      attr_reader :campaign, :tenant, :sleep_seconds

      def ensure_recipients!
        return if campaign.affiliate_campaign_recipients.exists?

        creators = Affiliates::FilterCreators.call(
          tenant: tenant, channel: campaign.channel, params: campaign.segment_filter
        )
        creators.find_each do |creator|
          campaign.affiliate_campaign_recipients.find_or_create_by!(affiliate_creator: creator)
        end
      end

      def pending_recipients
        campaign.affiliate_campaign_recipients.where(status: "pending")
      end

      def process_recipient(recipient)
        Integrations::Tiktok::AffiliateMessageSendService.call(
          affiliate_creator: recipient.affiliate_creator,
          content: campaign.message_template.to_s,
          campaign_recipient: recipient
        )
      rescue Integrations::RateLimitError => e
        @next_retry_at = Time.current + [ e.retry_after.to_f.to_i, 60 ].max
        @rate_limit_hit = true
      rescue => e
        recipient.update!(status: "failed", error_message: e.message.to_s.truncate(255))
      end

      def refresh_counts!
        campaign.update!(
          sent_count: campaign.affiliate_campaign_recipients.where(status: "sent").count,
          failed_count: campaign.affiliate_campaign_recipients.where(status: "failed").count
        )
      end

      def rate_limit_hit? = @rate_limit_hit
      def next_retry_at = @next_retry_at
    end
  end
end
