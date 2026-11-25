class CreateAffiliateVideos < ActiveRecord::Migration[7.2]
  def change
    # Videos posted for this tenant's TikTok shop by creators linked through
    # a target collaboration (affiliate_creators) — kept in sync by
    # Integrations::Tiktok::AffiliateVideoSyncService from Get Shop Video
    # Performance List (account_type AFFILIATE_ACCOUNTS). The video file
    # itself is an Active Storage attachment (AffiliateVideo#file), downloaded
    # by AffiliateVideoDownloadService; play_url is not stored because TikTok
    # signs it and it expires.
    create_table :affiliate_videos do |t|
      t.references :tenant,  null: false, foreign_key: true
      t.references :channel, null: false, foreign_key: true
      t.references :affiliate_creator, foreign_key: true
      # Which store connection synced it — the download asks that same
      # connection for the play_url (multi-store tenants have several).
      t.references :channel_credential, foreign_key: true

      t.string :video_id, null: false
      t.string :creator_open_id
      t.string :username
      t.string :nickname
      t.string :author_type
      t.text :title
      t.integer :duration_seconds
      t.datetime :posted_at
      t.jsonb :products, default: [], null: false
      t.jsonb :metrics, default: {}, null: false
      t.text :thumbnail_url
      # pending → queued → downloading → downloaded | failed
      t.string :download_status, default: "pending", null: false
      t.text :download_error
      t.datetime :downloaded_at
      t.jsonb :raw_payload, default: {}, null: false
      t.datetime :synced_at

      t.timestamps
    end

    add_index :affiliate_videos, [ :tenant_id, :channel_id, :video_id ],
      unique: true, name: "index_affiliate_videos_on_tenant_channel_video"
    add_index :affiliate_videos, [ :tenant_id, :posted_at ]
    add_index :affiliate_videos, [ :tenant_id, :download_status ]
  end
end
