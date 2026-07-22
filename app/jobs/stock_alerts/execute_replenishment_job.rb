module StockAlerts
  # The ONLY place that makes the real HTTP call to a channel for an
  # automatic/confirmed replenishment — deliberately separate from
  # OrderStockDeductionService's row lock (see that class) and from
  # StockAlertsController#confirm's request/response cycle. Enqueued by
  # StockAlerts::CreateReplenishmentExecution right after it creates a
  # "pending" StockReplenishmentExecution.
  class ExecuteReplenishmentJob < ApplicationJob
    queue_as :integrations

    def perform(execution_id)
      execution = StockReplenishmentExecution.find_by(id: execution_id)
      return unless execution

      # execution.with_lock so two accidental enqueues of the same id (job
      # retried by Sidekiq after a transient failure, e.g.) can't both pass
      # this check and both write to the channel.
      claimed = execution.with_lock do
        next false unless execution.status == "pending"

        execution.update!(status: "executing", started_at: Time.current, attempt_count: execution.attempt_count + 1)
        true
      end
      return unless claimed

      listing = execution.channel_product_listing

      # Re-check eligibility now, not just at creation time — the gap
      # between "crossing detected, execution created" and "job actually
      # runs" is normally seconds, but a channel sync could have flipped
      # eligibility in between (e.g. someone archived the product on
      # Shopify directly).
      unless listing.reload.replenishment_eligible?
        finish(execution, status: "skipped", error_message: "canal #{listing.channel} deixou de ser elegível antes da execução (selling_status=#{listing.selling_status})")
        return
      end

      begin
        previous_qty = listing.stock_qty
        response = StockAlerts::ReplenishmentExecutorService.write_stock(listing, execution.requested_qty)
        listing.update!(stock_qty: execution.requested_qty)

        StockMovement.record!(
          tenant: execution.tenant,
          product: execution.product,
          channel: listing.channel,
          kind: "entrada",
          previous_qty: previous_qty || 0,
          new_qty: listing.stock_qty,
          source: "replenishment"
        )

        finish(execution, status: "succeeded", confirmed_qty: execution.requested_qty, remote_response: { result: response }.as_json)
        execution.stock_alert&.update!(status: "executed", executed_at: Time.current, error_message: nil)
      rescue Integrations::AuthenticationError, Integrations::RateLimitError,
             Integrations::ApiError, Integrations::UnsupportedOperationError,
             NotImplementedError, ArgumentError => e
        finish(execution, status: "failed", error_message: e.message)
        execution.stock_alert&.update!(status: "failed", error_message: e.message)
      end
    end

    private

    def finish(execution, status:, error_message: nil, confirmed_qty: nil, remote_response: nil)
      execution.update!(
        status: status,
        error_message: error_message,
        confirmed_qty: confirmed_qty,
        remote_response: remote_response || execution.remote_response,
        finished_at: Time.current
      )
    end
  end
end
