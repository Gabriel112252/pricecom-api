class AddTiktokSellerImSenderIdToChannelCredentials < ActiveRecord::Migration[7.2]
  def change
    # Learned automatically, not user-input — see
    # Integrations::Tiktok::AffiliateConversationSyncService#learn_seller_sender_id.
    # TikTok's IM sender_id for the shop's own account is a per-shop
    # constant, but lives in a different id namespace than anything else
    # already stored on this credential (app_key/app_secret/access_token
    # are Partner Center/OAuth ids, not IM ids) — cached here once observed
    # on a message we know for certain we sent ourselves, and used from
    # then on to correctly tell inbound (creator) messages apart from
    # outbound (shop) ones.
    add_column :channel_credentials, :tiktok_seller_im_sender_id, :string
  end
end
