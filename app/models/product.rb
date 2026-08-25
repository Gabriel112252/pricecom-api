class Product < ApplicationRecord
  STORE_KEYS = %w[hidrabene anasol].freeze
  ANASOL_NAME_PATTERN = "%anasol%".freeze

  belongs_to :tenant
  # Qual integração de origem sincronizou dados deste produto. Hidrabene e
  # Anasol usam a MESMA conta IDWorks, portanto integration_id não representa
  # loja/marca e não deve ser usado para separar as duas operações.
  belongs_to :integration, optional: true
  has_many :order_items, dependent: :nullify
  has_many :pricing_rules, dependent: :destroy
  has_many :channel_operational_costs, dependent: :destroy
  has_many :audit_conflicts, dependent: :destroy

  has_many :kit_components, foreign_key: :kit_product_id, dependent: :destroy
  has_many :components, through: :kit_components, source: :component_product
  has_many :kit_memberships, foreign_key: :component_product_id, class_name: "KitComponent", dependent: :destroy

  has_many :channel_product_listings, dependent: :destroy
  has_many :stock_snapshots, dependent: :destroy
  has_many :stock_alert_rules, dependent: :destroy
  has_many :stock_alerts, dependent: :destroy
  has_many :stock_movements, dependent: :destroy
  has_many :stock_replenishment_executions, dependent: :destroy
  # testimonials/dependent: :nullify é o vínculo antigo (deprecado,
  # belongs_to :product singular em Testimonial — mantido só pra não exigir
  # rollback com perda de dado, ver Testimonial#product). O vínculo atual
  # (múltiplos produtos) é testimonial_products; sem dependent: :destroy
  # aqui, apagar um produto ainda vinculado a algum testimonial estoura
  # ActiveRecord::InvalidForeignKey (fk_rails_..._on_testimonial_products)
  # — a linha da junção some, o Testimonial em si não é afetado.
  has_many :testimonials, dependent: :nullify
  has_many :testimonial_products, dependent: :destroy

  validates :sku, presence: true, uniqueness: { scope: :tenant_id }
  validates :name, presence: true

  # A operação compartilha tenant, Yampi e IDWorks. Hoje o catálogo Anasol é
  # identificável pelo próprio nome do produto ("Anasol"); todo o restante
  # pertence ao agrupamento Hidrabene. Centralizar a regra aqui evita que
  # dashboard, depoimentos e relatórios inventem critérios diferentes.
  scope :for_store, lambda { |store_key|
    case store_key.to_s
    when "anasol"
      where("LOWER(products.name) LIKE ?", ANASOL_NAME_PATTERN)
    when "hidrabene"
      where.not("LOWER(products.name) LIKE ?", ANASOL_NAME_PATTERN)
    else
      none
    end
  }

  def self.store_key_for(product_name)
    product_name.to_s.downcase.include?("anasol") ? "anasol" : "hidrabene"
  end

  def store_key
    self.class.store_key_for(name)
  end

  # Physical stock (idworks' QtyAvailable, see qty_available's own comment
  # in the Fase 1 migration) not yet allocated to ANY sales channel —
  # qty_available already IS the ERP's total, so subtracting every
  # channel's stock_qty (including the one a StockAlert is currently
  # evaluating) isn't double-counting: it's "total minus what's already
  # spent everywhere," which is exactly the pool a replenishment can safely
  # draw from. See StockAlerts::EvaluationService for how this is used.
  def free_reserve
    qty_available.to_d - channel_product_listings.sum(:stock_qty).to_d
  end
end
