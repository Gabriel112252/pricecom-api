module StockAlerts
  # Safety-net reconciliation, NOT the primary alert/replenishment trigger.
  # The primary path is event-driven: OrderStockDeductionService (right
  # after a sale debits a channel), Integrations::ProductSyncService (right
  # after a channel sync writes stock_qty), and Integrations::Idworks::
  # StockSyncService (right after qty_available changes) each call
  # StockAlerts::EvaluationService directly when something that affects
  # Product#free_reserve just changed, which itself creates and enqueues a
  # StockReplenishmentExecution when warranted (see
  # StockAlerts::CreateReplenishmentExecution).
  #
  # Two separate things to catch here, both genuinely rare:
  #
  # 1. Executions stuck "executing" — StockAlerts::ExecuteReplenishmentJob
  #    marks a row "executing" then does the real HTTP call; if the Sidekiq
  #    process dies mid-call (deploy, OOM, hard crash) with no exception
  #    ever raised back into the job, the row never transitions to
  #    succeeded/failed and sits there forever — which matters because the
  #    partial unique index (see the migration) blocks any new attempt for
  #    that listing+rule while one is "in flight". Anything past
  #    STUCK_EXECUTING_AFTER is treated as failed, freeing that slot up.
  #
  # 2. Products with an active rule whose alert never got (re-)evaluated by
  #    the event-driven path — a bug in one of the three callers above, a
  #    manual DB fix that bypassed the app layer, or (once it exists) a
  #    manual central-pool adjustment not wired into the event path yet.
  #
  # Re-evaluates every product with an active rule on a schedule (see
  # config/schedule.yml) — deliberately not the tight cadence a primary
  # trigger would need, since it's a backstop, not the primary trigger.
  #
  # Do NOT turn this into the primary trigger by making it more frequent or
  # adding logic here that only this job runs — new "stock changed" call
  # sites should call EvaluationService directly, the same way the three
  # above do.
  class ReconcileAlertsJob < ApplicationJob
    queue_as :integrations

    STUCK_EXECUTING_AFTER = 30.minutes

    def perform
      reconcile_stuck_executions
      reconcile_products
    end

    private

    def reconcile_stuck_executions
      StockReplenishmentExecution.where(status: "executing").where("started_at < ?", STUCK_EXECUTING_AFTER.ago).find_each do |execution|
        execution.update!(
          status: "failed",
          error_message: "execução travada em 'executing' por mais de #{STUCK_EXECUTING_AFTER.inspect} — provável worker morto no meio do job; marcada como falha pela reconciliação",
          finished_at: Time.current
        )
      rescue => e
        Rails.logger.error("[StockAlerts::ReconcileAlertsJob] failed to unstick execution=#{execution.id}: #{e.message}")
      end
    end

    def reconcile_products
      StockAlertRule.active.includes(:product).find_each do |rule|
        reconcile(rule.product)
      end
    end

    def reconcile(product)
      StockAlerts::EvaluationService.call(product)
    rescue => e
      Rails.logger.error("[StockAlerts::ReconcileAlertsJob] failed for product=#{product.id}: #{e.message}")
    end
  end
end
