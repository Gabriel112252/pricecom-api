module Api
  module V1
    class FinancialSettlementsController < ApplicationController
      PER_PAGE_DEFAULT = 50
      PER_PAGE_MAX     = 100

      CSV_ALIASES = {
        external_id:       %w[external_id],
        external_order_id: %w[external_order_id order_id pedido numero_pedido pedido_id],
        gross_amount:      %w[gross_amount bruto valor_bruto venda_bruta],
        fee_amount:        %w[fee_amount taxa taxas fee],
        discount_amount:   %w[discount_amount desconto valor_desconto],
        refund_amount:     %w[refund_amount estorno valor_estorno reembolso],
        chargeback_amount: %w[chargeback_amount chargeback],
        net_amount:        %w[net_amount liquido valor_liquido recebido valor_recebido],
        transaction_type:  %w[transaction_type tipo tipo_transacao],
        transaction_date:  %w[transaction_date data data_transacao],
        payout_date:       %w[payout_date data_repasse repasse_em]
      }.freeze

      CSV_FIELD_BY_ALIAS = CSV_ALIASES.each_with_object({}) do |(field, aliases), acc|
        aliases.each { |a| acc[a] = field }
      end.freeze

      def index
        settlements = apply_filters(current_tenant.financial_settlements.includes(:financial_source, :channel))
          .order(period_start: :desc, created_at: :desc)

        per   = [[params.fetch(:per_page, PER_PAGE_DEFAULT).to_i, 1].max, PER_PAGE_MAX].min
        paged = settlements.page(params[:page]).per(per)

        render json: {
          financial_settlements: paged.map { |s| index_json(s) },
          meta:                  pagination_meta(paged)
        }
      end

      def show
        settlement = current_tenant.financial_settlements
          .includes(:financial_source, :channel, :financial_settlement_items)
          .find(params[:id])

        render json: show_json(settlement)
      end

      def create
        financial_source = current_tenant.financial_sources.find(create_params[:financial_source_id])
        channel     = current_tenant.channels.find(create_params[:channel_id])         if create_params[:channel_id].present?
        integration = current_tenant.integrations.find(create_params[:integration_id]) if create_params[:integration_id].present?

        settlement = nil

        ActiveRecord::Base.transaction do
          settlement = current_tenant.financial_settlements.create!(
            settlement_attrs.merge(financial_source: financial_source, channel: channel, integration: integration)
          )

          items_attrs.each do |item_attrs|
            item = settlement.financial_settlement_items.create!(item_attrs.merge(tenant: current_tenant))
            Financials::MatchSettlementItem.call(item)
          end

          recalculate_totals(settlement)
        end

        render json: show_json(settlement), status: :created
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      end

      def import
        return render json: { error: "Arquivo CSV não enviado" }, status: :unprocessable_entity unless params[:file].present?

        financial_source = current_tenant.financial_sources.find(import_params[:financial_source_id])
        channel = current_tenant.channels.find(import_params[:channel_id]) if import_params[:channel_id].present?

        rows = parse_csv_rows(params[:file])
        return render json: { error: "CSV inválido ou vazio" }, status: :unprocessable_entity if rows.blank?

        settlement = nil

        ActiveRecord::Base.transaction do
          settlement = current_tenant.financial_settlements.create!(
            financial_source:     financial_source,
            channel:              channel,
            external_id:          import_params[:external_id],
            period_start:         import_params[:period_start],
            period_end:           import_params[:period_end],
            expected_payout_date: import_params[:expected_payout_date],
            actual_payout_date:   import_params[:actual_payout_date],
            status:               import_params[:status].presence || "pending"
          )

          rows.each do |row|
            item = settlement.financial_settlement_items.create!(
              tenant:             current_tenant,
              external_id:        row[:external_id].presence || "#{settlement.external_id}-#{row[:row_number]}",
              external_order_id:  row[:external_order_id],
              transaction_type:   row[:transaction_type].presence || "sale",
              gross_amount:       row[:gross_amount],
              fee_amount:         row[:fee_amount],
              discount_amount:    row[:discount_amount],
              refund_amount:      row[:refund_amount],
              chargeback_amount:  row[:chargeback_amount],
              net_amount:         row[:net_amount],
              transaction_date:   row[:transaction_date],
              payout_date:        row[:payout_date]
            )

            Financials::MatchSettlementItem.call(item)
          end

          recalculate_totals(settlement)
        end

        render json: show_json(settlement), status: :created
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      end

      # Modelo de CSV para o usuário preencher e enviar em POST /financial_settlements/import.
      # Usa ";" como separador (facilita valores em formato brasileiro, ex: "149,90") e
      # cabeçalhos em português já reconhecidos por CSV_FIELD_BY_ALIAS:
      #   pedido         = número/id do pedido no canal de venda (mapeado para external_order_id,
      #                    usado para conciliar com a Order correspondente)
      #   valor_liquido  = valor que caiu (ou deve cair) na conta, após taxas/descontos (net_amount)
      #   tipo_transacao = aceita: sale, refund, fee, chargeback, adjustment, payout
      def template
        send_data template_csv,
                  type:        "text/csv; charset=utf-8",
                  filename:    "modelo_repasse_pricecom.csv",
                  disposition: "attachment"
      end

      private

      def template_csv
        <<~CSV
          pedido;valor_bruto;taxa;desconto;reembolso;chargeback;valor_liquido;tipo_transacao;data;data_repasse
          YAMPI-123456;149,90;0,00;0,00;0,00;0,00;149,90;sale;2026-07-09;2026-08-15
          SHOPIFY-1001;249,90;12,50;0,00;0,00;0,00;237,40;sale;2026-07-10;2026-08-16
          TIKTOK-9001;189,90;8,90;10,00;0,00;0,00;171,00;sale;2026-07-11;2026-08-17
          YAMPI-123457;100,00;0,00;0,00;50,00;0,00;50,00;refund;2026-07-12;2026-08-18
        CSV
      end

      def apply_filters(scope)
        scope = scope.where(financial_source_id: params[:financial_source_id]) if params[:financial_source_id].present?
        scope = scope.where(channel_id:          params[:channel_id])          if params[:channel_id].present?
        scope = scope.where(status:               params[:status])             if params[:status].present?

        scope = scope.where("period_start >= ?", params[:date_from]) if params[:date_from].present?
        scope = scope.where("period_start <= ?", params[:date_to])   if params[:date_to].present?

        scope = scope.where("expected_payout_date >= ?", params[:expected_from]) if params[:expected_from].present?
        scope = scope.where("expected_payout_date <= ?", params[:expected_to])   if params[:expected_to].present?

        scope
      end

      def create_params
        params.permit(
          :financial_source_id, :integration_id, :channel_id, :external_id,
          :period_start, :period_end,
          :gross_amount, :fee_amount, :discount_amount, :refund_amount, :chargeback_amount, :net_amount,
          :expected_payout_date, :actual_payout_date, :status,
          metadata: {},
          items: [
            :external_id, :external_order_id, :transaction_type,
            :gross_amount, :fee_amount, :discount_amount, :refund_amount, :chargeback_amount, :net_amount,
            :transaction_date, :payout_date,
            metadata: {}
          ]
        )
      end

      def settlement_attrs
        create_params.except(:financial_source_id, :integration_id, :channel_id, :items)
      end

      def items_attrs
        create_params[:items] || []
      end

      def import_params
        params.permit(
          :financial_source_id, :channel_id, :external_id,
          :period_start, :period_end,
          :expected_payout_date, :actual_payout_date, :status
        )
      end

      def parse_csv_rows(file)
        content = file.read.to_s
        content = content.force_encoding("UTF-8")
        return nil if content.strip.blank?

        first_line = content.each_line.first.to_s
        col_sep    = first_line.count(";") > first_line.count(",") ? ";" : ","

        table = CSV.parse(content, headers: true, col_sep: col_sep)
        return nil if table.headers.blank?

        table.each_with_index.map { |row, index| map_csv_row(row, index + 1) }
      rescue CSV::MalformedCSVError
        nil
      end

      def map_csv_row(row, row_number)
        mapped = {}
        row.headers.each do |header|
          next if header.nil?

          field = CSV_FIELD_BY_ALIAS[normalize_csv_header(header)]
          next unless field

          mapped[field] = row[header]
        end

        {
          external_id:       mapped[:external_id],
          external_order_id: mapped[:external_order_id],
          transaction_type:  mapped[:transaction_type],
          gross_amount:      parse_csv_decimal(mapped[:gross_amount]),
          fee_amount:        parse_csv_decimal(mapped[:fee_amount]),
          discount_amount:   parse_csv_decimal(mapped[:discount_amount]),
          refund_amount:     parse_csv_decimal(mapped[:refund_amount]),
          chargeback_amount: parse_csv_decimal(mapped[:chargeback_amount]),
          net_amount:        parse_csv_decimal(mapped[:net_amount]),
          transaction_date:  parse_csv_datetime(mapped[:transaction_date]),
          payout_date:       parse_csv_datetime(mapped[:payout_date])&.to_date,
          row_number:        row_number
        }
      end

      def normalize_csv_header(header)
        header.to_s.strip.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/_+/, "_").gsub(/\A_|_\z/, "")
      end

      def parse_csv_decimal(value)
        return 0 if value.blank?

        value.to_s.strip.gsub(",", ".").to_f
      end

      def parse_csv_datetime(value)
        return nil if value.blank?

        DateTime.parse(value.to_s)
      rescue ArgumentError, Date::Error
        nil
      end

      def recalculate_totals(settlement)
        items = settlement.financial_settlement_items

        settlement.update!(
          gross_amount:      items.sum(:gross_amount),
          fee_amount:        items.sum(:fee_amount),
          discount_amount:   items.sum(:discount_amount),
          refund_amount:     items.sum(:refund_amount),
          chargeback_amount: items.sum(:chargeback_amount),
          net_amount:        items.sum(:net_amount)
        )
      end

      def index_json(settlement)
        {
          id:                     settlement.id,
          financial_source_id:    settlement.financial_source_id,
          financial_source_name:  settlement.financial_source&.name,
          channel_id:             settlement.channel_id,
          channel_name:           settlement.channel&.name,
          external_id:            settlement.external_id,
          period_start:           settlement.period_start,
          period_end:             settlement.period_end,
          gross_amount:           settlement.gross_amount,
          fee_amount:             settlement.fee_amount,
          discount_amount:        settlement.discount_amount,
          refund_amount:          settlement.refund_amount,
          chargeback_amount:      settlement.chargeback_amount,
          net_amount:             settlement.net_amount,
          expected_payout_date:   settlement.expected_payout_date,
          actual_payout_date:     settlement.actual_payout_date,
          status:                 settlement.status,
          created_at:             settlement.created_at
        }
      end

      def show_json(settlement)
        index_json(settlement).merge(
          metadata: settlement.metadata,
          items:    settlement.financial_settlement_items.map { |i| item_json(i) }
        )
      end

      def item_json(item)
        {
          id:                 item.id,
          order_id:           item.order_id,
          external_order_id:  item.external_order_id,
          transaction_type:   item.transaction_type,
          gross_amount:       item.gross_amount,
          fee_amount:         item.fee_amount,
          discount_amount:    item.discount_amount,
          refund_amount:      item.refund_amount,
          chargeback_amount:  item.chargeback_amount,
          net_amount:         item.net_amount,
          expected_amount:    item.expected_amount,
          difference_amount:  item.difference_amount,
          status:             item.status,
          transaction_date:   item.transaction_date,
          payout_date:        item.payout_date
        }
      end

      def pagination_meta(paged)
        {
          current_page: paged.current_page,
          total_pages:  paged.total_pages,
          total_count:  paged.total_count,
          per_page:     paged.limit_value
        }
      end
    end
  end
end
