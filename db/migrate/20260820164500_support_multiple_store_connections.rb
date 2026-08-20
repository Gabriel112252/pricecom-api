class SupportMultipleStoreConnections < ActiveRecord::Migration[7.2]
  def up
    add_column :channel_credentials, :name, :string

    execute <<~SQL
      UPDATE channel_credentials
      SET name = CASE channel
        WHEN 'yampi' THEN 'Yampi'
        WHEN 'shopify' THEN 'Shopify'
        WHEN 'tiktok' THEN 'TikTok Shop'
        WHEN 'mercadolivre' THEN 'Mercado Livre'
        WHEN 'shopee' THEN 'Shopee'
        WHEN 'lucrofrete' THEN 'Lucrofrete'
        ELSE INITCAP(channel)
      END
      WHERE name IS NULL OR BTRIM(name) = ''
    SQL

    change_column_null :channel_credentials, :name, false

    remove_index :channel_credentials,
      name: "index_channel_credentials_on_tenant_id_and_channel"
    add_index :channel_credentials,
      [ :tenant_id, :channel, :name ],
      unique: true,
      name: "idx_channel_credentials_tenant_channel_name"

    add_reference :channel_product_listings,
      :channel_credential,
      null: true,
      foreign_key: { on_delete: :nullify }

    execute <<~SQL
      UPDATE channel_product_listings AS listings
      SET channel_credential_id = credentials.id
      FROM channel_credentials AS credentials
      WHERE credentials.tenant_id = listings.tenant_id
        AND credentials.channel = listings.channel
        AND listings.channel_credential_id IS NULL
    SQL

    remove_index :channel_product_listings,
      name: "idx_on_tenant_id_channel_external_id_a1d176e2c8"

    add_index :channel_product_listings,
      [ :tenant_id, :channel_credential_id, :external_id ],
      unique: true,
      where: "channel_credential_id IS NOT NULL",
      name: "idx_channel_listings_credential_external"

    add_index :channel_product_listings,
      [ :tenant_id, :channel, :external_id ],
      unique: true,
      where: "channel_credential_id IS NULL",
      name: "idx_channel_listings_legacy_external"

    add_reference :product_registration_publications,
      :channel_credential,
      null: true,
      foreign_key: { on_delete: :nullify }

    execute <<~SQL
      UPDATE product_registration_publications AS publications
      SET channel_credential_id = credentials.id
      FROM product_registrations AS registrations,
           channel_credentials AS credentials
      WHERE registrations.id = publications.product_registration_id
        AND credentials.tenant_id = registrations.tenant_id
        AND credentials.channel = publications.channel
        AND publications.channel_credential_id IS NULL
    SQL

    remove_index :product_registration_publications,
      name: "idx_product_registration_publications_channel"

    add_index :product_registration_publications,
      [ :product_registration_id, :channel_credential_id ],
      unique: true,
      where: "channel_credential_id IS NOT NULL",
      name: "idx_product_publications_registration_credential"

    add_index :product_registration_publications,
      [ :product_registration_id, :channel ],
      unique: true,
      where: "channel_credential_id IS NULL",
      name: "idx_product_publications_legacy_channel"
  end

  def down
    remove_index :product_registration_publications,
      name: "idx_product_publications_registration_credential"
    remove_index :product_registration_publications,
      name: "idx_product_publications_legacy_channel"
    remove_reference :product_registration_publications,
      :channel_credential,
      foreign_key: true
    add_index :product_registration_publications,
      [ :product_registration_id, :channel ],
      unique: true,
      name: "idx_product_registration_publications_channel"

    remove_index :channel_product_listings,
      name: "idx_channel_listings_credential_external"
    remove_index :channel_product_listings,
      name: "idx_channel_listings_legacy_external"
    remove_reference :channel_product_listings,
      :channel_credential,
      foreign_key: true
    add_index :channel_product_listings,
      [ :tenant_id, :channel, :external_id ],
      unique: true,
      name: "idx_on_tenant_id_channel_external_id_a1d176e2c8"

    remove_index :channel_credentials,
      name: "idx_channel_credentials_tenant_channel_name"
    remove_column :channel_credentials, :name
    add_index :channel_credentials,
      [ :tenant_id, :channel ],
      unique: true,
      name: "index_channel_credentials_on_tenant_id_and_channel"
  end
end
