class AddUtmFieldsToOrders < ActiveRecord::Migration[7.2]
  def change
    # Five separate string columns, not a single utm_data jsonb: UTM
    # (source/medium/campaign/content/term) is a fixed, industry-wide
    # querystring convention — not a Yampi-specific shape — so any future
    # channel with its own checkout populates the exact same five fields,
    # not a differently-shaped payload per channel (that's what jsonb
    # columns like financial_breakdown are for: genuinely heterogeneous
    # raw data). Plain columns also read naturally in a future dashboard
    # breakdown (GROUP BY orders.utm_source) without jsonb extraction.
    #
    # Confirmed against a real Yampi production payload (tenant Hidrabene,
    # 2026-07-28): all five fields sit loose at the payload root, no
    # include= needed — every sampled order had them nil, so nullable with
    # no default is the honest shape (a blank string would misrepresent
    # "no UTM data" as "UTM data with an empty value").
    add_column :orders, :utm_source,   :string
    add_column :orders, :utm_medium,   :string
    add_column :orders, :utm_campaign, :string
    add_column :orders, :utm_content,  :string
    add_column :orders, :utm_term,     :string
  end
end
