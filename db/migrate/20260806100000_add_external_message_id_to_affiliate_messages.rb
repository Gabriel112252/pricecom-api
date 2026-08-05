class AddExternalMessageIdToAffiliateMessages < ActiveRecord::Migration[7.2]
  def change
    # Dedupe key for Integrations::Tiktok::AffiliateConversationSyncService —
    # without it, re-syncing a conversation (pagination re-run, retry after a
    # rate limit) would insert the same TikTok message twice. Nullable + a
    # partial unique index because outbound messages sent through
    # AffiliateMessageSendService before this column existed (and any future
    # message source that doesn't have a TikTok message id) don't set it.
    add_column :affiliate_messages, :external_message_id, :string
    add_index :affiliate_messages, [ :affiliate_creator_id, :external_message_id ],
      unique: true, where: "external_message_id IS NOT NULL",
      name: "index_affiliate_messages_on_creator_and_external_message_id"
  end
end
