class CreateAffiliates < ActiveRecord::Migration[7.2]
  def change
    # TikTok Shop Affiliate Seller API (target_collaborations/conversations —
    # see TiktokAdapter's AFFILIATE_* paths). One row per creator linked to
    # this tenant's shop through a target collaboration plan, kept in sync by
    # Integrations::Tiktok::AffiliateSyncService. conversation_id is filled in
    # lazily on the first message sent (Create Conversation with creator),
    # not by the sync itself — the sync never opens a conversation.
    create_table :affiliate_creators do |t|
      t.references :tenant,  null: false, foreign_key: true
      t.references :channel, null: false, foreign_key: true

      t.string :creator_open_id, null: false
      t.string :username
      t.string :nickname
      t.string :avatar_url
      t.string :collaboration_status
      t.integer :showcase_product_count, default: 0, null: false
      t.integer :content_product_count, default: 0, null: false
      t.string :target_collaboration_id
      t.string :conversation_id
      # free_sample_rule.has_free_sample provavelmente vive no objeto de
      # produto do target_collaboration, não no de criador — ver nota no
      # plano de implementação; coluna gravada mesmo assim, exposta na UI só
      # depois de confirmar a extração contra o raw_payload real.
      t.boolean :has_free_sample, default: false, null: false
      t.jsonb :raw_payload, default: {}, null: false
      t.datetime :synced_at

      t.timestamps
    end

    add_index :affiliate_creators, [ :tenant_id, :channel_id, :creator_open_id ],
      unique: true, name: "index_affiliate_creators_on_tenant_channel_open_id"

    # affiliate_campaign_recipients.affiliate_message_id (added below) is the
    # only FK between the two tables — a campaign recipient points at the
    # message it produced. Not modeled the other way around (a
    # affiliate_campaign_recipient_id column here) to avoid a circular FK
    # between two tables created in the same migration.
    create_table :affiliate_messages do |t|
      t.references :affiliate_creator, null: false, foreign_key: true
      t.string :conversation_id
      t.string :direction, null: false # outbound/inbound
      t.text :content
      t.datetime :sent_at
      t.jsonb :raw_payload, default: {}, null: false

      t.timestamps
    end

    add_index :affiliate_messages, [ :affiliate_creator_id, :sent_at ]

    create_table :affiliate_campaigns do |t|
      t.references :tenant,  null: false, foreign_key: true
      t.references :channel, null: false, foreign_key: true

      t.string :name, null: false
      t.jsonb :segment_filter, default: {}, null: false
      t.text :message_template
      t.string :status, default: "draft", null: false # draft/sending/completed
      t.integer :sent_count, default: 0, null: false
      t.integer :failed_count, default: 0, null: false
      t.references :created_by, foreign_key: { to_table: :users }

      t.timestamps
    end

    create_table :affiliate_campaign_recipients do |t|
      t.references :affiliate_campaign, null: false, foreign_key: true
      t.references :affiliate_creator, null: false, foreign_key: true
      t.references :affiliate_message, foreign_key: true
      t.string :status, default: "pending", null: false # pending/sent/failed
      t.string :error_message
      t.datetime :sent_at

      t.timestamps
    end

    add_index :affiliate_campaign_recipients, [ :affiliate_campaign_id, :affiliate_creator_id ],
      unique: true, name: "index_affiliate_campaign_recipients_on_campaign_creator"

    # Snapshot diário só pro gráfico de evolução da aba Visão Geral — mesmo
    # padrão de ShopAnalyticsSnapshot. Escrito 1x por sync bem-sucedido
    # (upsert do dia corrente), não por webhook/evento.
    create_table :affiliate_daily_snapshots do |t|
      t.references :tenant,  null: false, foreign_key: true
      t.references :channel, null: false, foreign_key: true

      t.date :snapshot_date, null: false
      t.integer :active_creators_count, default: 0, null: false
      t.integer :total_creators_count, default: 0, null: false
      t.integer :showcase_product_count_total, default: 0, null: false
      t.integer :content_product_count_total, default: 0, null: false

      t.timestamps
    end

    add_index :affiliate_daily_snapshots, [ :tenant_id, :channel_id, :snapshot_date ],
      unique: true, name: "index_affiliate_daily_snapshots_on_tenant_channel_date"
  end
end
