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
    # the drawer) never inserts the same message twice. When a fetched
    # message already exists locally AND is tagged "outbound", that's also
    # the trigger for #learn_seller_sender_id — see its comment and
    # #infer_direction for the direction bug this fixes (confirmed in
    # production, Hidrabene, 2026-08-06: every synced message was being
    # misfiled as outbound, including real creator replies).
    class AffiliateConversationSyncService
      def self.call(affiliate_creator:) = new(affiliate_creator).call

      def initialize(affiliate_creator)
        @affiliate_creator = affiliate_creator
        @tenant = affiliate_creator.tenant
        @channel_credential = tenant.channel_credentials.find_by!(channel: "tiktok")
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

      attr_reader :affiliate_creator, :tenant, :adapter, :channel_credential

      def persist_messages(messages)
        messages.each do |entry|
          body = entry["message_body"] || {}
          external_id = body["id"].to_s
          next if external_id.blank?

          existing = AffiliateMessage.find_by(affiliate_creator: affiliate_creator, external_message_id: external_id)
          if existing
            # A blank raw_payload can ONLY happen for a row created by
            # AffiliateMessageSendService (the sync always sets raw_payload
            # to the full API entry) — that's the one reliable signal that
            # this pre-existing row is DEFINITELY ours, not just tagged
            # "outbound" (which, on rows the sync itself inserted, can't be
            # trusted before this fix — see #infer_direction's comment).
            # Seeing it come back through the sync with its real sender_id
            # is the one moment we can safely learn the shop's own IM
            # sender_id, see #learn_seller_sender_id.
            learn_seller_sender_id(body["sender_id"]) if existing.raw_payload.blank?
            next
          end

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

      # BUG FIXED 2026-08-06 (confirmed in production, tenant Hidrabene):
      # this used to compare sender_id against AffiliateCreator#creator_open_id,
      # but those are two different TikTok id namespaces — creator_open_id
      # is the Affiliate/Collaboration system's id, sender_id/sender_im_user_id
      # is the internal IM system's id. They never match, so every synced
      # message fell through to the "outbound" fallback — including two real
      # replies from a creator (fabibessa_) that got recorded as if the shop
      # had sent them.
      #
      # The real signal: the shop's own sender_id is a constant PER SHOP,
      # not per conversation — confirmed the same value
      # ("7497814839709541074" for Hidrabene) showed up on every genuine
      # outbound message across multiple different creators. That value is
      # learned automatically (see #learn_seller_sender_id) and cached on
      # ChannelCredential#tiktok_seller_im_sender_id.
      #
      # Until it's learned (freshly connected credential, or the very first
      # sync ever with no confirmed outbound message seen yet), there is no
      # reliable way to tell inbound from outbound — defaulting to
      # "inbound" here is the deliberately conservative choice: one of our
      # own messages being mislabeled inbound is far less harmful than
      # silently hiding a real creator reply as if we had sent it.
      #
      # The creator_open_id comparison is kept as a fallback even though
      # it's known to never match in practice — harmless, and cheap
      # insurance in case that ever turns out wrong.
      def infer_direction(sender_id)
        seller_id = channel_credential.tiktok_seller_im_sender_id
        return "outbound" if seller_id.present? && sender_id.to_s == seller_id.to_s
        return "outbound" if sender_id.to_s == affiliate_creator.creator_open_id.to_s
        "inbound"
      end

      # Learns ChannelCredential#tiktok_seller_im_sender_id the first time
      # we recognize an incoming synced message as one we already know for
      # certain is ours (see the `existing.direction == "outbound"` guard in
      # #persist_messages). Never overwrites an already-confirmed value —
      # once learned, it's treated as a stable per-shop constant, not
      # something to keep re-deriving.
      def learn_seller_sender_id(sender_id)
        return if sender_id.blank?
        return if channel_credential.tiktok_seller_im_sender_id.present?

        channel_credential.update!(tiktok_seller_im_sender_id: sender_id.to_s)
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
