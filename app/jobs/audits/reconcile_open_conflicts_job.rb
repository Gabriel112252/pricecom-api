module Audits
  # Revalida periodicamente as pendencias abertas da area Operacao depois que
  # os pollings dos sistemas externos atualizaram o estado local do Pricecom.
  #
  # A ideia aqui nao e criar outra fonte de verdade nem refazer todos os syncs.
  # Yampi, TikTok, Shopee, IDWorks, Pagar.me etc. continuam sendo atualizados
  # pelos schedulers proprios em config/schedule.yml. Este job apenas fecha o
  # ciclo do alerta: detectou -> fonte atualizou -> revalida -> resolve se sumiu.
  #
  # Excecoes:
  # - missing_cost: o sync completo de custo da IDWorks roda normalmente a cada
  #   6h. Enquanto existir conflito aberto desse tipo, permitimos uma checagem
  #   extraordinaria no maximo 1x/h para capturar uma correcao manual no ERP.
  # - order_qty_mismatch: mesma ideia para a reconciliacao Pricecom x IDWorks,
  #   respeitando DataSourceConfig e limitando a 1x/h enquanto houver conflito.
  class ReconcileOpenConflictsJob < ApplicationJob
    queue_as :integrations

    ORDER_CONFLICT_TYPES = %w[
      missing_cost
      gift_costing_error
      nf_discount_mismatch
      nf_freight_mismatch
      refund_without_cancellation
    ].freeze

    EXTERNAL_REFRESH_INTERVAL = 1.hour

    def perform
      tenant_ids_with_open_conflicts.find_each do |tenant|
        reconcile_order_conflicts(tenant)
        refresh_missing_cost_source(tenant)
        refresh_order_quantity_source(tenant)
      rescue => e
        Rails.logger.error(
          "[Audits::ReconcileOpenConflictsJob] tenant=#{tenant.id} failed: #{e.class}: #{e.message}"
        )
      end
    end

    private

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

    def refresh_missing_cost_source(tenant)
      return unless tenant.audit_conflicts.open.where(conflict_type: "missing_cost").exists?
      return unless DataSourceConfig.source_for(tenant, "cost") == "idworks"

      connected_idworks_integrations(tenant).find_each do |integration|
        next if recent_success?(integration, "idworks_product_cost_sync")

        Integrations::Idworks::ProductCostSyncJob.perform_later(integration.id)
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
