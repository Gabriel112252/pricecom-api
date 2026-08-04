module Integrations
  module Tiktok
    # Sends one message to one creator, individually or as part of a
    # campaign batch (see AffiliateCampaignDispatchService). Does not
    # rescue anything — callers decide how to handle RateLimitError/
    # AuthenticationError/etc (a controller renders an error, a campaign
    # batch pauses and reschedules).
    class AffiliateMessageSendService
      def self.call(affiliate_creator:, content:, campaign_recipient: nil)
        new(affiliate_creator: affiliate_creator, content: content, campaign_recipient: campaign_recipient).call
      end

      def initialize(affiliate_creator:, content:, campaign_recipient: nil)
        @affiliate_creator = affiliate_creator
        @content = content
        @campaign_recipient = campaign_recipient
        channel_credential = affiliate_creator.tenant.channel_credentials.find_by!(channel: "tiktok")
        @adapter = Integrations::TiktokAdapter.new(channel_credential.credentials)
      end

      def call
        ensure_conversation!
        adapter.send_message(conversation_id: affiliate_creator.conversation_id, content: content)

        message = AffiliateMessage.create!(
          affiliate_creator: affiliate_creator,
          conversation_id: affiliate_creator.conversation_id,
          direction: "outbound",
          content: content,
          sent_at: Time.current
        )
        campaign_recipient&.update!(status: "sent", affiliate_message: message, sent_at: Time.current)
        message
      end

      private

      attr_reader :affiliate_creator, :content, :campaign_recipient, :adapter

      def ensure_conversation!
        return if affiliate_creator.conversation_id.present?

        data = adapter.create_conversation(creator_open_id: affiliate_creator.creator_open_id)
        affiliate_creator.update!(conversation_id: data["conversation_id"])
      end
    end
  end
end
