module Products
  # Recursively resolves a sold product/quantity into the real (non-kit)
  # products actually consumed. Deliberately decoupled from inventory —
  # it only returns the flattened consumption data; stock deduction
  # (Etapa 7) will be built on top of this.
  class ExplodeKit
    MAX_DEPTH = KitComponent::MAX_NESTING_DEPTH

    def self.call(product, quantity)
      new.call(product, quantity)
    end

    def call(product, quantity, depth = 0)
      return [{ product: product, real_qty: quantity }] unless product.is_kit? && depth < MAX_DEPTH

      components = product.kit_components.includes(:component_product)
      return [] if components.empty?

      components.flat_map do |kit_component|
        call(kit_component.component_product, quantity * kit_component.quantity, depth + 1)
      end
    end
  end
end
