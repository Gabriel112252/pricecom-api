module Api
  module V1
    class AuditConflictsController < ApplicationController
      PER_PAGE_DEFAULT = 50
      PER_PAGE_MAX     = 100

      before_action :require_admin!, only: [ :reprocess ]

      # Tipos temporariamente desativados como pendencia operacional. Eles
      # continuam acessiveis quando filtrados explicitamente e no historico,
      # mas nao entram na fila aberta padrao nem nos seus contadores.
      DISABLED_DEFAULT_CONFLICT_TYPES = %w[missing_cost].freeze

      # Alertas de comportamento e de integracao operacional pertencem a
      # Operacao, nao a tela de Auditoria. Internamente reaproveitam
      # AuditConflict para ciclo open/resolved e historico sem exigir uma
      # segunda infraestrutura de alertas.
      OPERATIONAL_ONLY_CONFLICT_TYPES = %w[
        order_volume_drop
        sku_volume_drop
        yampi_order_not_integrated
      ].freeze

      SEVERITY_ORDER_SQL = <<~SQL.squish
        CASE audit_conflicts.severity
          WHEN 'critical' THEN 0
          WHEN 'high'     THEN 1
          WHEN 'medium'   THEN 2
          WHEN 'low'      THEN 3
          ELSE 4
        END
      SQL

      STATUS_ORDER_SQL = <<~SQL.squish
        CASE WHEN audit_conflicts.status = 'open' THEN 0 ELSE 1 END
      SQL

      def index
        # Scoped by every filter except status, so tab counters reflect the
        # active type/severity/channel/search filters regardless of which tab is open.
        scoped = apply_filters(current_tenant.audit_conflicts.includes(:order, :product, :resolved_by), except: :status)
        conflicts = params[:status].present? ? scoped.where(status: params[:status]) : scoped
        conflicts = conflicts
          .order(Arel.sql(STATUS_ORDER_SQL))
          .order(Arel.sql(SEVERITY_ORDER_SQL))
          .order(created_at: :desc)

        per   = [[params.fetch(:per_page, PER_PAGE_DEFAULT).to_i, 1].max, PER_PAGE_MAX].min
        paged = conflicts.page(params[:page]).per(per)

        render json: {
          audit_conflicts: paged.map { |c| index_json(c) },
          meta:            pagination_meta(paged),
          status_counts:   status_counts(scoped)
        }
      end

      def show
        conflict = current_tenant.audit_conflicts
          .includes(:product, :resolved_by, order: :channel)
          .find(params[:id])

        render json: show_json(conflict)
      end

      def update
        conflict = current_tenant.audit_conflicts.find(params[:id])

        apply_status_transition(conflict, audit_conflict_params[:status]) if audit_conflict_params[:status].present?

        if conflict.update(audit_conflict_params)
          render json: show_json(conflict)
        else
          render json: { errors: conflict.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # Manual recovery for the specific incident exposed by the
      # Yampi/IDWorks integrator. Pricecom never recreates the integration
      # rules here; it asks the source service to revalidate and enqueue its
      # own SyncYampiOrderToIdworksJob.
      def reprocess
        conflict = current_tenant.audit_conflicts.find(params[:id])

        unless conflict.conflict_type == "yampi_order_not_integrated"
          render json: { error: "Este conflito não suporta reprocessamento" }, status: :unprocessable_entity
          return
        end

        upstream_id = conflict.metadata.to_h["webhook_event_id"] || conflict.metadata.to_h["id"]
        if upstream_id.blank?
          render json: { error: "Pendência sem identificador do integrador" }, status: :unprocessable_entity
          return
        end

        result = Integrations::YampiIdworksIntegratorClient.new.reprocess(upstream_id)

        if result["status"] == "already_resolved"
          conflict.update!(status: "resolved", resolved_at: Time.current, resolved_by: nil)
        elsif result["status"] == "queued"
          conflict.update!(
            metadata: conflict.metadata.to_h.merge(
              "manual_reprocess_queued_at" => Time.current.iso8601,
              "manual_reprocess_queued_by_id" => current_user.id
            )
          )
        end

        render json: {
          success: true,
          status: result["status"],
          conflict: index_json(conflict.reload)
        }
      rescue Integrations::YampiIdworksIntegratorClient::Error => error
        render json: { error: error.message }, status: :bad_gateway
      end

      private

      def apply_filters(scope, except: [])
        except = Array(except)

        scope = scope.where(status:        params[:status])        if params[:status].present? && !except.include?(:status)
        scope = scope.where(conflict_type: params[:conflict_type]) if params[:conflict_type].present?

        if params[:conflict_type].blank?
          excluded_types = []
          excluded_types.concat(DISABLED_DEFAULT_CONFLICT_TYPES) if active_queue_request?
          excluded_types.concat(OPERATIONAL_ONLY_CONFLICT_TYPES) unless operational_queue_request?
          scope = scope.where.not(conflict_type: excluded_types) if excluded_types.any?
        end

        scope = scope.where(severity:   params[:severity])   if params[:severity].present?
        scope = scope.where(order_id:   params[:order_id])   if params[:order_id].present?
        scope = scope.where(product_id: params[:product_id]) if params[:product_id].present?

        scope = scope.where("audit_conflicts.created_at >= ?", params[:date_from]) if params[:date_from].present?
        scope = scope.where("audit_conflicts.created_at <= ?", params[:date_to])   if params[:date_to].present?

        if params[:channel].present? || params[:q].present?
          scope = scope.left_joins(:order, :product)
        end

        scope = scope.where(orders: { channel_id: params[:channel] }) if params[:channel].present?

        if params[:q].present?
          term = "%#{params[:q]}%"
          scope = scope.where(
            "orders.order_number ILIKE :q OR products.name ILIKE :q OR products.sku ILIKE :q OR audit_conflicts.notes ILIKE :q",
            q: term
          )
        end

        scope
      end

      def active_queue_request?
        params[:status].blank? || params[:status] == "open"
      end

      def operational_queue_request?
        params[:operational_queue].to_s == "true"
      end

      def status_counts(scoped)
        counts = scoped.group(:status).count
        AuditConflict::STATUSES.index_with { |status| counts[status] || 0 }
      end

      # Nunca permite alterar expected_value/actual_value/difference via API.
      def audit_conflict_params
        params.permit(:status, :notes)
      end

      def apply_status_transition(conflict, new_status)
        if new_status == "open"
          conflict.resolved_at = nil
          conflict.resolved_by = nil
        elsif %w[resolved ignored].include?(new_status)
          conflict.resolved_at = Time.current
          conflict.resolved_by = current_user
        end
      end

      def index_json(conflict)
        {
          id:               conflict.id,
          conflict_type:    conflict.conflict_type,
          severity:         conflict.severity,
          status:           conflict.status,
          order_id:         conflict.order_id,
          order_number:     conflict.order&.order_number,
          product_id:       conflict.product_id,
          product_sku:      conflict.product&.sku,
          expected_value:   conflict.expected_value,
          actual_value:     conflict.actual_value,
          difference:       conflict.difference,
          source:           conflict.source,
          metadata:         presentation_metadata(conflict),
          created_at:       conflict.created_at,
          updated_at:       conflict.updated_at,
          resolved_at:      conflict.resolved_at,
          resolved_by_id:   conflict.resolved_by_id,
          resolved_by_name: conflict.resolved_by&.name
        }
      end

      # A tela de Operacao antiga ja renderiza metadata.sku diretamente. Para
      # incluir o canal sem criar um alerta separado por canal (e sem aumentar
      # o ruido), enriquecemos apenas a representacao JSON. O metadata salvo no
      # banco continua com o SKU puro, usado pela deteccao/resolucao.
      def presentation_metadata(conflict)
        metadata = conflict.metadata.to_h.deep_dup
        return metadata unless conflict.conflict_type == "sku_volume_drop"

        breakdown = Array(metadata["channel_breakdown"])
        affected = breakdown.select { |row| row.to_h["affected"] == true }
        selected = affected.any? ? affected : breakdown
        channel_names = selected.filter_map { |row| row.to_h["channel_name"].to_s.presence }.uniq
        sku = metadata["sku"].to_s.presence

        metadata["sku"] = "#{sku} [#{channel_names.join(', ')}]" if sku && channel_names.any?
        metadata
      end

      def show_json(conflict)
        index_json(conflict).merge(
          notes:    conflict.notes,
          order:    order_summary(conflict.order),
          product:  product_summary(conflict.product)
        )
      end

      def order_summary(order)
        return nil unless order

        {
          external_id:   order.external_id,
          channel_name:  order.channel&.name,
          customer_name: order.customer_name,
          gross_value:   order.gross_value,
          status:        order.status
        }
      end

      def product_summary(product)
        return nil unless product

        {
          sku:        product.sku,
          name:       product.name,
          cost_price: product.cost_price
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
