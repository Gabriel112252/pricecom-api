class CreateTestimonials < ActiveRecord::Migration[7.2]
  def change
    create_table :testimonials do |t|
      t.references :tenant,  null: false, foreign_key: true
      t.references :product, null: true,  foreign_key: true

      t.string :source_type, null: false, default: "manual" # manual | tiktok | shopee
      t.string :status,      null: false, default: "draft"  # draft | approved | published | rejected

      t.string :customer_name, null: false
      t.integer :rating
      t.text :quote_text

      # Link original: URL do vídeo no TikTok, ou original_url do review na Shopee.
      t.string :external_url

      # Cache do oEmbed do TikTok (título, autor, thumbnail_url) — evita
      # rechamar a API externa toda vez que o depoimento é exibido/editado.
      t.jsonb :tiktok_metadata, null: false, default: {}

      t.datetime :approved_at
      t.datetime :published_at

      t.timestamps
    end

    add_index :testimonials, [ :tenant_id, :status ]
    add_index :testimonials, [ :tenant_id, :source_type ]
    add_index :testimonials, [ :tenant_id, :product_id ]
  end
end
