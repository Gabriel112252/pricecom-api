class ProductRegistration < ApplicationRecord
  STATUSES = %w[draft ready publishing waiting_channels published partial_failure failed].freeze

  belongs_to :tenant
  belongs_to :parent_product, class_name: "Product"
  belongs_to :product, optional: true
  belongs_to :created_by_user, class_name: "User", optional: true

  has_many :publications,
    class_name: "ProductRegistrationPublication",
    dependent: :destroy,
    inverse_of: :product_registration
  has_many_attached :images

  validates :sku, presence: true
  validates :name, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :price_cents,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 },
    allow_nil: true

  validate :parent_product_belongs_to_tenant
  validate :generated_product_belongs_to_tenant

  private

  def parent_product_belongs_to_tenant
    return if parent_product.blank? || tenant.blank? || parent_product.tenant_id == tenant_id

    errors.add(:parent_product, "deve pertencer à mesma empresa")
  end

  def generated_product_belongs_to_tenant
    return if product.blank? || tenant.blank? || product.tenant_id == tenant_id

    errors.add(:product, "deve pertencer à mesma empresa")
  end
end
