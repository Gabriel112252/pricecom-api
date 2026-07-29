class TestimonialProduct < ApplicationRecord
  belongs_to :testimonial
  belongs_to :product

  validates :product_id, uniqueness: { scope: :testimonial_id }

  # Vive aqui, não em Testimonial — Testimonial#product_ids= (has_many
  # :through) grava/apaga linhas desta tabela direto via
  # ActiveRecord::RecordInvalid (create!/destroy!), sem passar por
  # Testimonial#save. Se essa checagem ficasse só lá, um cross-tenant
  # product_id passado por Testimonial#product_ids= entraria sem validação
  # nenhuma.
  validate :product_belongs_to_same_tenant

  private

  def product_belongs_to_same_tenant
    return if product.nil? || testimonial.nil?

    errors.add(:product, "inválido") unless product.tenant_id == testimonial.tenant_id
  end
end
