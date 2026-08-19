require "csv"

module Api
  module V1
    class CustomersController < ApplicationController
      def index
        render json: Customers::BaseQuery.call(tenant: current_tenant, params: params)
      end

      def overview
        render json: Customers::Overview.call(tenant: current_tenant)
      end

      def rfm
        render json: Customers::Rfm.call(tenant: current_tenant)
      end

      def export
        export_params = params.to_unsafe_h.merge("page" => 1, "per_page" => Customers::BaseQuery::MAX_PER_PAGE)
        first_page = Customers::BaseQuery.call(tenant: current_tenant, params: export_params)
        rows = first_page[:rows]
        total_pages = first_page.dig(:meta, :total_pages).to_i

        (2..total_pages).each do |page|
          payload = Customers::BaseQuery.call(
            tenant: current_tenant,
            params: export_params.merge("page" => page)
          )
          rows.concat(payload[:rows])
        end

        csv = CSV.generate(headers: true) do |out|
          out << [
            "Nome", "E-mail", "UF", "Pedidos", "Valor total", "Ticket médio",
            "Primeira compra", "Última compra", "Dias sem comprar", "Canal de entrada",
            "SKU de entrada", "SKUs comprados"
          ]

          rows.each do |row|
            out << [
              row[:name], row[:email], row[:state], row[:orders_count], row[:total_spent], row[:average_ticket],
              row[:first_purchase_at], row[:last_purchase_at], row[:recency_days], row.dig(:first_channel, :name),
              row[:first_sku], Array(row[:purchased_skus]).join(" | ")
            ]
          end
        end

        send_data csv,
          filename: "clientes-#{Date.current.iso8601}.csv",
          type: "text/csv; charset=utf-8",
          disposition: "attachment"
      end
    end
  end
end
