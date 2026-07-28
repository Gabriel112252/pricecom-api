class AddAffiliateAdsAndPartnerCommissionToOrders < ActiveRecord::Migration[7.2]
  def change
    # TikTok's Finance API fee_tax_breakdown.fee carries three distinct
    # affiliate-related fee keys (see
    # Integrations::Tiktok::FinancialTransactionParser::FEE_FIELDS):
    # affiliate_commission_amount (organic creator commission, already
    # persisted), affiliate_ads_commission_amount (commission on
    # affiliate-driven PAID ads) and affiliate_partner_commission_amount
    # (commission owed to an Affiliate Partner/agency). The latter two were
    # being summed into the generic other_fees_amount bucket, losing the
    # distinction — same precision/scale as their sibling
    # affiliate_commission_amount (added in
    # 20260721100000_add_financial_fields_to_orders.rb).
    add_column :orders, :affiliate_ads_commission_amount,     :decimal, precision: 12, scale: 2, default: 0, null: false
    add_column :orders, :affiliate_partner_commission_amount, :decimal, precision: 12, scale: 2, default: 0, null: false
  end
end
