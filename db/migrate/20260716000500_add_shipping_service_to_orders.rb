class AddShippingServiceToOrders < ActiveRecord::Migration[7.2]
  # O serviço de frete escolhido pelo cliente (ex: "ECONOMICO_-_LOGGI_EXPRESS"),
  # persistido para casar o pedido com a opção correspondente em
  # freight_quotes.quotes mesmo quando a cotação chega DEPOIS do pedido.
  def change
    add_column :orders, :shipping_service, :string
  end
end
