class KitComponent < ApplicationRecord
  MAX_NESTING_DEPTH = 3

  belongs_to :kit_product, class_name: "Product"
  belongs_to :component_product, class_name: "Product"

  validates :quantity, numericality: { greater_than: 0 }
  validates :component_product_id, uniqueness: { scope: :kit_product_id }

  validate :component_is_not_self
  validate :no_circular_reference
  validate :max_nesting_depth

  private

  def component_is_not_self
    return unless kit_product_id.present? && kit_product_id == component_product_id

    errors.add(:base, "o componente não pode ser o próprio kit")
  end

  def no_circular_reference
    return unless kit_product_id.present? && component_product_id.present?
    return if errors[:base].present?

    if contained_product_ids(component_product_id).include?(kit_product_id)
      errors.add(:base, "referência circular: este produto já contém o kit atual")
    end
  end

  def max_nesting_depth
    return unless kit_product_id.present? && component_product_id.present?
    return if errors[:base].present?

    total_depth = depth_above(kit_product_id) + 1 + depth_below(component_product_id)
    return unless total_depth > MAX_NESTING_DEPTH

    errors.add(:base, "excede o limite de #{MAX_NESTING_DEPTH} níveis de aninhamento de kits")
  end

  # Products transitively contained by `product_id` as kit components (excludes itself).
  def contained_product_ids(product_id, visited = Set.new)
    KitComponent.where(kit_product_id: product_id).find_each do |kc|
      next if visited.include?(kc.component_product_id)

      visited << kc.component_product_id
      contained_product_ids(kc.component_product_id, visited)
    end
    visited
  end

  def depth_below(product_id, seen = Set.new)
    return 0 if seen.include?(product_id)

    seen << product_id
    children = KitComponent.where(kit_product_id: product_id).pluck(:component_product_id)
    return 0 if children.empty?

    1 + children.map { |id| depth_below(id, seen) }.max
  end

  def depth_above(product_id, seen = Set.new)
    return 0 if seen.include?(product_id)

    seen << product_id
    parents = KitComponent.where(component_product_id: product_id).pluck(:kit_product_id)
    return 0 if parents.empty?

    1 + parents.map { |id| depth_above(id, seen) }.max
  end
end
