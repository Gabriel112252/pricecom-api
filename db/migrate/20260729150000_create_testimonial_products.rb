class CreateTestimonialProducts < ActiveRecord::Migration[7.2]
  def up
    create_table :testimonial_products do |t|
      t.references :testimonial, null: false, foreign_key: true
      t.references :product,     null: false, foreign_key: true

      t.timestamps
    end

    add_index :testimonial_products, [ :testimonial_id, :product_id ], unique: true

    backfill_from_deprecated_product_id
  end

  def down
    drop_table :testimonial_products
  end

  # Todo Testimonial#product_id já preenchido (a coluna antiga, 1 produto
  # só) vira o registro equivalente aqui. A coluna product_id é só
  # DEPRECADA por enquanto (não removida) — não há passo de rollback pronto
  # se algo dependendo dela ainda não tiver migrado pro has_many :products,
  # through: :testimonial_products. Método público (não privado) só pra dar
  # pra chamar isolado a partir de spec/db/migrate/create_testimonial_products_spec.rb,
  # sem precisar recriar a tabela.
  def backfill_from_deprecated_product_id
    execute <<~SQL
      INSERT INTO testimonial_products (testimonial_id, product_id, created_at, updated_at)
      SELECT id, product_id, NOW(), NOW()
      FROM testimonials
      WHERE product_id IS NOT NULL
    SQL
  end
end
