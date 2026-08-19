module Audits
  # Revalida periodicamente as pendencias abertas da area Operacao depois que
  # os pollings dos sistemas externos atualizaram o estado local do Pricecom.
  #
  # A ideia aqui nao e criar outra fonte de verdade nem refazer todos os syncs.
  # Yampi, TikTok, Shopee, IDWorks, Pagar.me etc. continuam sendo atualizados
  # pelos schedulers proprios em config/schedule.yml. Este job apenas fecha o
  # ciclo do alerta: detectou -> fonte atualizou -> revalida -> resolve se sumiu.
  #
  # missing_cost esta temporariamente desativado como pendencia operacional.
  # Os registros antigos desse tipo sao resolvidos em lote no inicio do job,
  # sem reprocessar pedido por pedido nem disparar sync extraordinario de custo.
  class ReconcileOpenConflictsJob < ApplicationJob
    queue_as :integrations

    ORDER_CONFLICT_TYPES = %w[
      gift_costing_error
      nf_discount_mismatch
      nf_freight_mismatch
      refund_without_cancellation
    ].freeze

    EXTERNAL_REFRESH_INTERVAL = 1.hour

    def perform
      resolve_disabled_missing_cost_conflicts

      tenant_ids_with_open_conflicts.find_each do |tenant|
        reconcile_order_conflicts(tenant)
        refresh_order_quantity_source(tenant)
      rescue => e
        Rails.logger.error(
          "[Audits::ReconcileOpenConflictsJob] tenant=#{tenant.id} failed: #{e.class}: #{e.message}"
        )
      end
    end

    private

    def resolve_disabled_missing_cost_conflicts
      now = Time.current
      resolved_count = AuditConflict
        .open
        .where(conflict_type: "missing_cost")
        .update_all(status: "resolved", resolved_at: now, updated_at: now)

      Rails.logger.info(
        "[Audits::ReconcileOpenConflictsJob] resolved_disabled_missing_cost=#{resolved_count}"
      ) if resolved_count.positive?
    end

    def tenant_ids_with_open_conflicts
      Tenant
        .joins(:audit_conflicts)
        .merge(AuditConflict.open)
        .distinct
    end

    def reconcile_order_conflicts(tenant)
      order_ids = tenant.audit_conflicts
        .open
        .where(conflict_type: ORDER_CONFLICT_TYPES)
        .where.not(order_id: nil)
        .distinct
        .pluck(:order_id)

      tenant.orders.where(id: order_ids).find_each do |order|
        Audits::DetectOrderConflicts.call(order)
      rescue => e
        Rails.logger.error(
          "[Audits::ReconcileOpenConflictsJob] order=#{order.id} failed: #{e.class}: #{e.message}"
        )
      end
    end

    def refresh_order_quantity_source(tenant)
      return unless tenant.audit_conflicts.open.where(conflict_type: "order_qty_mismatch").exists?
      return unless DataSourceConfig.source_for(tenant, "order_reconciliation") == "idworks"

      connected_idworks_integrations(tenant).find_each do |integration|
        next if recent_success?(integration, "idworks_reconciliation")

        Integrations::Idworks::OrderReconciliationJob.perform_later(
          integration.id,
          1.week.ago.to_date.iso8601,
          Date.current.iso8601
        )
      end
    end

    def connected_idworks_integrations(tenant)
      tenant.integrations.where(provider: "idworks", status: "connected")
    end

    def recent_success?(integration, action)
      IntegrationSyncLog
        .where(integration: integration, action: action, status: "success")
        .where("finished_at >= ?", EXTERNAL_REFRESH_INTERVAL.ago)
        .exists?
    end
  end
end
