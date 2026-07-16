class AddTiktokUnpaidSupportToOrders < ActiveRecord::Migration[7.2]
  def up
    # Auditoria do frete TikTok (payment object do Get Order Detail):
    # shipping_fee (cobrado do cliente) já é persistido em orders.freight;
    # estes três guardam a decomposição para auditoria.
    add_column :orders, :original_shipping_fee,          :decimal, precision: 10, scale: 2
    add_column :orders, :shipping_fee_platform_discount, :decimal, precision: 10, scale: 2
    add_column :orders, :shipping_fee_seller_discount,   :decimal, precision: 10, scale: 2

    # orders.status é string livre (cada canal grava verbatim) — não há enum
    # de banco. O valor canônico de "pedido criado sem pagamento" passa a ser
    # 'unpaid' (Order::NON_REVENUE_STATUSES); o polling TikTok já ingeria
    # pedidos UNPAID verbatim, então normaliza o legado para o valor canônico.
    execute <<~SQL
      UPDATE orders SET status = 'unpaid' WHERE LOWER(status) = 'unpaid' AND status <> 'unpaid';
    SQL

    # A reconciliação TikTok varre pedidos unpaid por tenant a cada execução.
    add_index :orders, "tenant_id, LOWER(status)", name: "index_orders_on_tenant_id_and_lower_status"
  end

  def down
    remove_index :orders, name: "index_orders_on_tenant_id_and_lower_status"
    remove_column :orders, :original_shipping_fee
    remove_column :orders, :shipping_fee_platform_discount
    remove_column :orders, :shipping_fee_seller_discount
  end
end
