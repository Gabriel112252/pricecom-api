require "rails_helper"

# testimonial_products (a tabela em si) já existe no schema de teste — essa
# migration já rodou. O que ainda não tem cobertura é a lógica de backfill
# (#backfill_from_deprecated_product_id), que só roda uma vez, na primeira
# vez que a migration é aplicada num banco com dados antigos. Carrega o
# arquivo da migration e chama só esse método isolado, sem re-rodar
# create_table/add_index (que já existem e quebrariam se rodassem de novo).
load Rails.root.join("db/migrate/20260729150000_create_testimonial_products.rb")

RSpec.describe CreateTestimonialProducts do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:product) { tenant.products.create!(sku: "SKU-1", name: "Produto 1", cost_price: 10) }

  def legacy_testimonial_with_product_id(product)
    testimonial = tenant.testimonials.create!(customer_name: "Ana", source_type: "manual", status: "draft")
    # Simula dado de ANTES desta migration existir: product_id preenchido
    # direto na coluna (bypassa validação/associação — update_column não
    # roda callbacks), sem nenhum TestimonialProduct correspondente ainda.
    testimonial.update_column(:product_id, product.id)
    testimonial
  end

  it "creates a testimonial_products row for every testimonial with a legacy product_id" do
    testimonial = legacy_testimonial_with_product_id(product)

    expect { described_class.new.backfill_from_deprecated_product_id }
      .to change { testimonial.reload.testimonial_products.count }.from(0).to(1)

    expect(testimonial.testimonial_products.first.product_id).to eq(product.id)
  end

  it "does nothing for testimonials without a legacy product_id" do
    testimonial = tenant.testimonials.create!(customer_name: "Sem produto", source_type: "manual", status: "draft")

    expect { described_class.new.backfill_from_deprecated_product_id }
      .not_to change { testimonial.reload.testimonial_products.count }
  end

  it "is safe to run twice (idempotent) thanks to the unique index on [testimonial_id, product_id]" do
    legacy_testimonial_with_product_id(product)

    described_class.new.backfill_from_deprecated_product_id
    expect { described_class.new.backfill_from_deprecated_product_id }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "backfills every matching testimonial, not just one" do
    other_product = tenant.products.create!(sku: "SKU-2", name: "Produto 2", cost_price: 5)
    t1 = legacy_testimonial_with_product_id(product)
    t2 = legacy_testimonial_with_product_id(other_product)

    described_class.new.backfill_from_deprecated_product_id

    expect(t1.reload.product_ids).to eq([ product.id ])
    expect(t2.reload.product_ids).to eq([ other_product.id ])
  end
end
