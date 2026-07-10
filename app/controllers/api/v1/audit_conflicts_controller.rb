module Api
  module V1
    class AuditConflictsController < ApplicationController
      PER_PAGE_DEFAULT = 50
      PER_PAGE_MAX     = 100

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

      private

      def apply_filters(scope, except: [])
        except = Array(except)

        scope = scope.where(status:        params[:status])        if params[:status].present? && !except.include?(:status)
        scope = scope.where(conflict_type: params[:conflict_type])  if params[:conflict_type].present?
        scope = scope.where(severity:      params[:severity])       if params[:severity].present?
        scope = scope.where(order_id:      params[:order_id])       if params[:order_id].present?
        scope = scope.where(product_id:    params[:product_id])     if params[:product_id].present?

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
          created_at:       conflict.created_at,
          resolved_at:      conflict.resolved_at,
          resolved_by_id:   conflict.resolved_by_id,
          resolved_by_name: conflict.resolved_by&.name
        }
      end

      def show_json(conflict)
        index_json(conflict).merge(
          notes:    conflict.notes,
          metadata: conflict.metadata,
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
