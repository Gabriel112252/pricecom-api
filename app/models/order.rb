class Order < ApplicationRecord
  belongs_to :tenant
  belongs_to :channel
  has_many :order_items,          dependent: :destroy
  has_many :order_refunds,        dependent: :destroy
  has_many :audit_conflicts,      dependent: :destroy
  has_many :financial_settlement_items, dependent: :nullify
  has_many :financial_receivables, dependent: :nullify
  has_many :lucrofrete_order_reports, dependent: :nullify
  has_many :integration_mappings, as: :mappable, dependent: :nullify
  has_many :converted_carts, class_name: "Cart", foreign_key: :converted_order_id,
    dependent: :nullify, inverse_of: :converted_order

  # "sample" — amostra grátis enviada a criador/afiliado (TikTok Shop
  # Affiliate: order_type "SELLER_FUND_FREE_SAMPLE" / is_sample_order true
  # na Order API), não é venda de cliente. unit_price/gross_value vêm
  # genuinamente zerados da própria API, não é bug de sync — mas precisa
  # ficar fora de sales_and_refunds pra não contaminar volume/receita.
  ORDER_TYPES = %w[sale refund cancellation exchange sample].freeze

  # Statuses que nunca contam como venda: 'unpaid' (pedido TikTok criado sem
  # pagamento — o proxy de carrinho abandonado do canal) e 'status_unknown'
  # (unpaid cujo desfecho não pôde ser determinado pela reconciliação).
  # Toda query de faturamento/volume/ticket deve passar por
  # `revenue_countable` para não ser contaminada por eles.
  NON_REVENUE_STATUSES = %w[unpaid status_unknown].freeze

  # orders.status chega dos canais em grafias mistas ("cancelled" e
  # "CANCELLED" convivem em produção) — todo filtro por status de
  # cancelamento DEVE comparar via LOWER, nunca igualdade exata.
  CANCELED_STATUS_ALIASES = %w[cancelado canceled cancelled cancelada].freeze

  validates :order_type, inclusion: { in: ORDER_TYPES }

  before_save :calculate_margin

  scope :canceled,     -> { where("LOWER(COALESCE(orders.status, '')) IN (?)", CANCELED_STATUS_ALIASES) }
  scope :not_canceled, -> { where.not("LOWER(COALESCE(orders.status, '')) IN (?)", CANCELED_STATUS_ALIASES) }
  scope :active,       -> { not_canceled }
  scope :revenue_countable, -> { where.not("LOWER(COALESCE(orders.status, '')) IN (?)", NON_REVENUE_STATUSES) }
  scope :sales,        -> { where(order_type: "sale") }
  scope :cancellations, -> { where(order_type: "cancellation") }
  scope :refunds,      -> { where(order_type: "refund") }

  # A definição canônica de "conta como venda/faturamento real": sale ou
  # refund, não cancelado, revenue_countable. Antes desta mudança essa
  # combinação exata vivia duplicada à mão em 4 lugares (financial_orders
  # em BuildSummary, BuildCustomers, freight_comparable_orders e
  # tiktok_orders_scope em DashboardController) — e as 6 queries a nível
  # item (rankings/busca/giro/evolução de produto) usavam só
  # revenue_countable sozinho, sem excluir cancelamento nem order_type
  # "sample"/"exchange". NÃO usar em orders_in_period/canceled_amount_for/
  # build_returns_and_refunds (BuildSummary) — esses 3 precisam ver pedido
  # cancelado de propósito, ver comentário lá.
  scope :sales_and_refunds, -> { where(order_type: %w[sale refund]).not_canceled.revenue_countable }

  # margin_pct e a coluna decimal(5,2): valores fora de +-999.99 estouram o insert
  MARGIN_PCT_RANGE = (-999.99..999.99)

  def calculate_margin
    if tiktok_financially_synced?
      self.margin = if settlement_amount.nil?
        revenue_amount.to_f - fee_and_tax_amount.to_f - cost_price.to_f
      else
        settlement_amount.to_f - cost_price.to_f
      end
      margin_denominator = revenue_amount.to_f
    else
      self.margin = gross_value.to_f - cost_price.to_f - effective_freight_cost - discount.to_f - commission.to_f - operational_cost.to_f - effective_tax_amount
      margin_denominator = gross_value.to_f
    end

    self.margin_pct = margin_denominator > 0 ? (margin / margin_denominator * 100).round(2).clamp(MARGIN_PCT_RANGE.min, MARGIN_PCT_RANGE.max) : 0
  end

  def tiktok_financially_synced?
    channel&.platform.to_s.casecmp?("tiktok") &&
      respond_to?(:financial_synced_at) && financial_synced_at.present? &&
      respond_to?(:settlement_amount) && respond_to?(:revenue_amount) && respond_to?(:fee_and_tax_amount)
  end

  def net_gross_value
    (gross_value.to_f - refund_amount.to_f).round(2)
  end

  def net_margin
    (margin.to_f - refund_amount.to_f).round(2)
  end

  def net_margin_pct
    return 0.0 unless gross_value.to_f > 0
    (net_margin / gross_value.to_f * 100).round(2).clamp(MARGIN_PCT_RANGE.min, MARGIN_PCT_RANGE.max)
  end

  # Fontes cujo custo real de frete é persistido em real_freight_cost —
  # idworks (sync do ERP) e lucrofrete (pedidos casados pelo parceiro, ver
  # Integrations::Lucrofrete::OrdersSyncService).
  REAL_FREIGHT_COST_SOURCES = %w[idworks lucrofrete].freeze

  def effective_freight_cost
    REAL_FREIGHT_COST_SOURCES.include?(DataSourceConfig.source_for(tenant, "freight")) ? real_freight_cost.to_f : freight.to_f
  end

  def effective_tax_amount
    DataSourceConfig.source_for(tenant, "tax").present? ? tax_amount.to_f : 0.0
  end
end
