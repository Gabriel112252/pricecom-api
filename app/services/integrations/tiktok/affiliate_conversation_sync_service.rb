module Integrations
  module Tiktok
    # Syncs the full message history of one AffiliateCreator's conversation
    # (Get Message in the Conversation — see TiktokAdapter#fetch_conversation_messages
    # and its class-comment entry for the confirmed payload shape). Called
    # on-demand when the "Detalhe do criador" drawer opens, not on a
    # schedule — deliberately no lock/IntegrationSyncLog machinery like
    # AffiliateSyncService, same reasoning as AffiliateMessageSendService's
    # simplicity: this is a single-conversation, request-scoped read, not a
    # tenant-wide backfill.
    #
    # Dedupe is by AffiliateMessage#external_message_id (TikTok's own
    # message id) scoped to the creator — re-running this (e.g. reopening
    # the drawer) never inserts the same message twice.
    class AffiliateConversationSyncService
      def self.call(affiliate_creator:) = new(affiliate_creator).call

      def initialize(affiliate_creator)
        @affiliate_creator = affiliate_creator
        @tenant = affiliate_creator.tenant
        channel_credential = tenant.channel_credentials.find_by!(channel: "tiktok")
        @adapter = Integrations::TiktokAdapter.new(channel_credential.credentials)
      end

      def call
        return if affiliate_creator.conversation_id.blank?

        page_token = nil
        loop do
          data = adapter.fetch_conversation_messages(
            conversation_id: affiliate_creator.conversation_id,
            page_token: page_token
          )
          persist_messages(data["messages"] || [])
          page_token = data["next_page_token"]
          break unless data["has_more"] && page_token.present?
        end
      end

      private

      attr_reader :affiliate_creator, :tenant, :adapter

      def persist_messages(messages)
        messages.each do |entry|
          body = entry["message_body"] || {}
          external_id = body["id"].to_s
          next if external_id.blank?
          next if AffiliateMessage.exists?(affiliate_creator: affiliate_creator, external_message_id: external_id)

          AffiliateMessage.create!(
            affiliate_creator: affiliate_creator,
            conversation_id: body["conversation_id"],
            external_message_id: external_id,
            direction: infer_direction(body["sender_id"]),
            content: parse_content(body["content"]),
            sent_at: Time.zone.at(body["create_time"].to_i),
            raw_payload: entry
          )
        end
      end

      # Confirmed in production (Hidrabene, 2026-08-06): the response has no
      # sender.role/nickname, only a bare sender_id. Our own outbound
      # sender_id is constant across every message the shop sends (observed
      # the same value on 3 real messages) and never matches any
      # AffiliateCreator#creator_open_id — so a match means the CREATOR sent
      # it (inbound), anything else is us (outbound). See TiktokAdapter's
      # class comment for the same confirmation.
      def infer_direction(sender_id)
        sender_id.to_s == affiliate_creator.creator_open_id.to_s ? "inbound" : "outbound"
      end

      # Same doubly-nested {"content": "..."} shape as #send_message's
      # request body — see TiktokAdapter#send_message's comment.
      def parse_content(raw)
        JSON.parse(raw.to_s)["content"]
      rescue JSON::ParserError
        raw.to_s
      end
    end
  end
end
