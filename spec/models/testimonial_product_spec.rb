require "rails_helper"

RSpec.describe TestimonialProduct do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:product) { tenant.products.create!(sku: "SKU-1", name: "Produto 1", cost_price: 10) }
  let(:testimonial) { tenant.testimonials.create!(customer_name: "Ana", source_type: "manual", status: "draft") }

  it "is valid linking a testimonial to a product of the same tenant" do
    link = TestimonialProduct.new(testimonial: testimonial, product: product)
    expect(link).to be_valid
  end

  it "rejects linking the same product twice to the same testimonial" do
    TestimonialProduct.create!(testimonial: testimonial, product: product)
    duplicate = TestimonialProduct.new(testimonial: testimonial, product: product)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:product_id]).to be_present
  end

  it "rejects a product that belongs to a different tenant than the testimonial" do
    other_tenant = Tenant.create!(name: "Outra Loja", slug: "outra-#{SecureRandom.hex(4)}")
    other_product = other_tenant.products.create!(sku: "SKU-X", name: "Produto X", cost_price: 10)

    link = TestimonialProduct.new(testimonial: testimonial, product: other_product)

    expect(link).not_to be_valid
    expect(link.errors[:product]).to be_present
  end

  it "destroying the product removes the link but leaves the testimonial itself intact" do
    TestimonialProduct.create!(testimonial: testimonial, product: product)

    expect { product.destroy! }.to change(TestimonialProduct, :count).by(-1)
    expect(Testimonial.exists?(testimonial.id)).to be true
  end
end
