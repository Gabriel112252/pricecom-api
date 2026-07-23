module Integrations
  module Tiktok
    # Historical, order-scoped Finance API backfill. It never re-runs order
    # ingestion: only OrderFinancialSyncService may update the financial
    # columns for the existing order.
    class FinancialBackfillService
      ACTION = "tiktok_financial_backfill"
      ELIGIBLE_STATUSES = %w[delivered completed].freeze
      MAX_ERROR_SAMPLES = 20
      DEFAULT_BATCH_SIZE = 50
      DEFAULT_BATCH_SLEEP = 0.5

      Result = Struct.new(:outcome, :error_message, :retry_after, :metadata, keyword_init: true) do
        def success? = outcome == :success
        def pending? = outcome == :pending
        def error? = outcome == :error
        def skipped? = outcome == :skipped
        def rate_limited? = outcome == :rate_limited
      end

      # PendingStatementError is preferred. These patterns only classify an
      # untyped ApiError when its message explicitly says the statement is not
      # available yet; a statement that is merely "ready" is never pending.
      PENDING_STATEMENT_PATTERNS = [
        /statement\s+(?:is\s+)?not\s+(?:yet\s+)?ready/i,
        /statement\s+(?:is\s+)?not\s+found/i,
        /statement\s+unavailable/i,
        /settlement\s+pending/i,
        /demonstrativo\s+indisponível/i,
        /demonstrativo\s+ainda\s+não\s+disponível/i
      ].freeze

      def self.call(
        channel_credential,
        batch_size: DEFAULT_BATCH_SIZE,
        batch_sleep: DEFAULT_BATCH_SLEEP,
        force: false,
        max_orders: nil,
        run_id: nil
      )
        new(
          channel_credential,
          batch_size: batch_size,
          batch_sleep: batch_sleep,
          force: force,
          max_orders: max_orders,
          run_id: run_id
        ).call
      end

      def self.clear_due_continuation!(channel_credential:, force:, run_id:)
        log = run_log(channel_credential, force, run_id)
        return false unless log

        cleared = false
        log.with_lock do
          metadata = log.metadata || {}
          continuation_run_at = timestamp_from_metadata(metadata["continuation_run_at"])

          if continuation_run_at && continuation_run_at <= Time.current
            metadata.delete("continuation_scheduled_at")
            metadata.delete("continuation_run_at")
            log.update!(metadata: metadata)
            cleared = true
          end
        end
        cleared
      end

      def self.claim_continuation!(channel_credential:, force:, run_id:, continuation_run_at:)
        log = run_log(channel_credential, force, run_id)
        return false unless log

        scheduled = false
        log.with_lock do
          metadata = log.metadata || {}
          existing_continuation_times = [
            timestamp_from_metadata(metadata["continuation_scheduled_at"]),
            timestamp_from_metadata(metadata["continuation_run_at"])
          ].compact

          unless existing_continuation_times.any? { |time| time > Time.current }
            metadata["continuation_scheduled_at"] = Time.current
            metadata["continuation_run_at"] = continuation_run_at
            metadata["continuation_count"] = metadata.fetch("continuation_count", 0).to_i + 1
            log.update!(status: "pending", finished_at: nil, metadata: metadata)
            scheduled = true
          end
        end
        scheduled
      end

      def self.run_log(channel_credential, force, run_id)
        return unless run_id.present?

        IntegrationSyncLog
          .where(tenant: channel_credential.tenant, action: ACTION, status: %w[pending error])
          .order(created_at: :desc)
          .find do |candidate|
            metadata = candidate.metadata || {}
            metadata["channel_credential_id"].to_s == channel_credential.id.to_s &&
              ActiveModel::Type::Boolean.new.cast(metadata["force"]) == force &&
              metadata["run_id"].to_s == run_id.to_s
          end
      end

      def self.timestamp_from_metadata(value)
        return value if value.is_a?(Time)
        return if value.blank?

        Time.zone.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      private_class_method :run_log, :timestamp_from_metadata

      def initialize(channel_credential, batch_size:, batch_sleep:, force:, max_orders: nil, run_id: nil)
        @channel_credential = channel_credential
        @tenant = channel_credential.tenant
        @batch_size = batch_size.to_i.positive? ? batch_size.to_i : DEFAULT_BATCH_SIZE
        @batch_sleep = batch_sleep.to_f.positive? ? batch_sleep.to_f : 0
        @force = force == true
        @max_orders = max_orders.nil? ? nil : [ max_orders.to_i, 0 ].max
        @run_id = run_id.to_s.presence
        @adapter = Integrations::TiktokAdapter.new(channel_credential.credentials)
        @lock = FinancialSyncLock.new(channel_credential)
        initialize_counters
      end

      def call
        @channel = tenant.channels.find_by(platform: "tiktok")
        return result(:skipped, "canal tiktok não encontrado") unless channel

        unless lock.acquire
          raise FinancialSyncLock::LockBusyError,
            "backfill financeiro TikTok já está em execução"
        end

        @lock_acquired = true
        resume_or_start_log
        process_batches
        status = final_status
        finish_log(status)
        result_for(status)
      rescue Integrations::AuthenticationError => e
        finish_log("error", e.message)
        result(:error, e.message)
      rescue FinancialSyncLock::LockLostError => e
        finish_log("error", e.message)
        raise
      rescue Integrations::RateLimitError => e
        @rate_limit_count += 1
        persist_checkpoint(error_message: "rate_limited: #{e.message}") if log
        raise
      ensure
        lock.release if lock_acquired
      end

      private

      attr_reader :channel_credential, :tenant, :adapter, :lock, :channel, :log,
        :batch_size, :batch_sleep, :max_orders, :error_samples, :pending_samples, :run_id

      def initialize_counters
        @total_orders = 0
        @eligible_orders = 0
        @processed_count = 0
        @run_started_processed_count = 0
        @run_processed_count = 0
        @run_target_count = max_orders
        @continuation_scheduled_at = nil
        @continuation_run_at = nil
        @continuation_count = 0
        @rate_limit_count = 0
        @synced_count = 0
        @skipped_count = 0
        @pending_statement_count = 0
        @error_count = 0
        @remaining_orders = 0
        @last_order_id = nil
        @last_batch_at = nil
        @run_started_at = nil
        @pass_count = 0
        @pass_completed = false
        @error_samples = []
        @pending_samples = []
        @lock_acquired = false
      end

      def resume_or_start_log
        @log = resumable_log

        if log
          restore_checkpoint
          start_next_pass if pass_completed
          return
        end

        start_new_log(latest_checkpoint_log)
      end

      def resumable_log
        IntegrationSyncLog
          .where(tenant: tenant, action: ACTION, status: %w[pending error])
          .order(created_at: :desc)
          .find do |candidate|
            metadata = candidate.metadata || {}
            metadata["channel_credential_id"].to_s == channel_credential.id.to_s &&
              boolean_metadata(metadata["force"]) == force &&
              same_run?(metadata["run_id"])
          end
      end

      def latest_checkpoint_log
        IntegrationSyncLog
          .where(tenant: tenant, action: ACTION)
          .order(created_at: :desc)
          .find do |candidate|
            metadata = candidate.metadata || {}
            metadata["channel_credential_id"].to_s == channel_credential.id.to_s &&
              boolean_metadata(metadata["force"]) == force
          end
      end

      def start_new_log(checkpoint_log = nil)
        restore_global_checkpoint(checkpoint_log)
        @run_started_at = Time.current if force
        @run_started_processed_count = processed_count
        @run_processed_count = 0
        @run_target_count = max_orders
        refresh_scope_counts
        @log = IntegrationSyncLog.create!(
          tenant: tenant,
          direction: "inbound",
          action: ACTION,
          status: "pending",
          started_at: Time.current,
          metadata: metadata_snapshot
        )
      end

      def restore_checkpoint
        metadata = log.metadata || {}
        @total_orders = metadata["total_orders"].to_i
        @eligible_orders = metadata["eligible_orders"].to_i
        @processed_count = metadata["processed_count"].to_i
        @run_started_processed_count = metadata.fetch("run_started_processed_count", @processed_count).to_i
        @run_processed_count = metadata.fetch("run_processed_count", 0).to_i
        @run_target_count = metadata.key?("run_target_count") && !metadata["run_target_count"].nil? ?
          metadata["run_target_count"].to_i : max_orders
        @max_orders = @run_target_count
        @continuation_scheduled_at = metadata["continuation_scheduled_at"]
        @continuation_run_at = metadata["continuation_run_at"]
        @continuation_count = metadata["continuation_count"].to_i
        @rate_limit_count = metadata["rate_limit_count"].to_i
        @synced_count = metadata["synced_count"].to_i
        @skipped_count = metadata["skipped_count"].to_i
        @pending_statement_count = metadata["pending_statement_count"].to_i
        @error_count = metadata["error_count"].to_i
        @remaining_orders = metadata["remaining_orders"].to_i
        @last_order_id = metadata["last_order_id"].presence
        @last_batch_at = metadata["last_batch_at"]
        @run_started_at = timestamp_from_metadata(metadata["run_started_at"])
        @run_started_at ||= log.started_at if force
        @pass_count = metadata["pass_count"].to_i
        @pass_completed = boolean_metadata(metadata["pass_completed"])
        @error_samples = Array(metadata["error_samples"]).first(MAX_ERROR_SAMPLES)
        @pending_samples = Array(metadata["pending_samples"]).first(MAX_ERROR_SAMPLES)
      end

      def restore_global_checkpoint(checkpoint_log)
        return unless checkpoint_log

        metadata = checkpoint_log.metadata || {}
        @processed_count = metadata["processed_count"].to_i
        @last_order_id = metadata["last_order_id"].presence if checkpoint_log.status == "pending"
      end

      def same_run?(stored_run_id)
        run_id.present? && stored_run_id.present? && stored_run_id.to_s == run_id
      end

      def start_next_pass
        @pass_completed = false
        @last_order_id = nil
        @last_batch_at = nil
        @pending_statement_count = 0
        @pending_samples = []
        @error_count = 0
        @error_samples = []
        refresh_scope_counts
      end

      def refresh_scope_counts
        @total_orders = all_candidate_orders.count
        @eligible_orders = eligible_orders_without_checkpoint.count
        @skipped_count = @total_orders - @eligible_orders
        @remaining_orders = @eligible_orders
      end

      def process_batches
        capacity = remaining_capacity
        return if capacity && capacity <= 0

        scope = eligible_orders
        scope = scope.limit(capacity) if capacity

        # batch_size controls only the number fetched per batch. max_orders
        # limits the complete operation, including retries after a checkpoint.
        scope.find_in_batches(batch_size: batch_size) do |orders|
          renew_lock!
          orders.each_with_index do |order, index|
            process_order(order)
            renew_lock! if (index + 1) % 10 == 0
          end
          persist_checkpoint
          renew_lock!
          sleep(batch_sleep) if batch_sleep.positive? && orders.length == batch_size
        end
      end

      def renew_lock!
        return if lock.renew

        raise FinancialSyncLock::LockLostError,
          "lock do backfill financeiro TikTok foi perdido"
      end

      def process_order(order)
        handled = false
        options = {
          order: order,
          channel_credential: channel_credential,
          adapter: adapter
        }
        options[:force] = true if force
        Integrations::Tiktok::OrderFinancialSyncService.call(**options)
        @processed_count += 1
        @run_processed_count += 1
        @synced_count += 1
        handled = true
      rescue Integrations::AuthenticationError, Integrations::RateLimitError, Faraday::Error, ActiveRecord::Deadlocked
        raise
      rescue Integrations::Tiktok::OrderFinancialSyncService::PendingStatementError => e
        @processed_count += 1
        @run_processed_count += 1
        record_pending(order, e.message)
        handled = true
      rescue Integrations::ApiError => e
        @processed_count += 1
        @run_processed_count += 1
        if pending_statement_error?(e)
          record_pending(order, e.message)
        else
          record_error(order, e.message)
        end
        handled = true
      rescue => e
        @processed_count += 1
        @run_processed_count += 1
        record_error(order, e.message)
        handled = true
      ensure
        update_last_order_id(order) if handled
      end

      def all_candidate_orders
        channel.orders.where(status_scope)
      end

      def eligible_orders_without_checkpoint
        scope = all_candidate_orders
        return scope.where(financial_synced_at: nil) unless force

        synced_before_run = scope.where("orders.financial_synced_at < ?", run_started_at)
        scope.where(financial_synced_at: nil).or(synced_before_run)
      end

      def eligible_orders
        scope = eligible_orders_without_checkpoint
        return scope.order(:id) unless last_order_id.present?

        scope.where("orders.id > ?", last_order_id.to_i).order(:id)
      end

      def remaining_scope_after_checkpoint
        return eligible_orders_without_checkpoint unless last_order_id.present?

        eligible_orders_without_checkpoint.where("orders.id > ?", last_order_id.to_i)
      end

      def status_scope
        [ "LOWER(COALESCE(orders.status, '')) IN (?)", ELIGIBLE_STATUSES ]
      end

      def update_last_order_id(order)
        @last_order_id = [ last_order_id.to_i, order.id ].max
      end

      def record_pending(order, message)
        @pending_statement_count += 1
        return if pending_samples.size >= MAX_ERROR_SAMPLES

        pending_samples << format_sample(order, message)
      end

      def record_error(order, message)
        @error_count += 1
        return if error_samples.size >= MAX_ERROR_SAMPLES

        error_samples << format_sample(order, message)
      end

      def format_sample(order, message)
        "order_id=#{order.id} external_id=#{order.external_id}: #{message}"
      end

      def pending_statement_error?(error)
        PENDING_STATEMENT_PATTERNS.any? { |pattern| error.message.to_s.match?(pattern) }
      end

      def persist_checkpoint(error_message: nil)
        @remaining_orders = eligible_orders_without_checkpoint.count
        @last_batch_at = Time.current
        log.update!(
          status: "pending",
          finished_at: nil,
          error_message: error_message,
          metadata: metadata_for_persistence
        )
      end

      def finalize_pass
        @remaining_orders = eligible_orders_without_checkpoint.count

        return "error" if error_count.positive?

        if remaining_orders.zero?
          @pending_statement_count = 0
          @pending_samples = []
          return "success"
        end

        return "pending" unless only_pending_orders_remain?

        @pass_count += 1
        @last_order_id = nil
        @pass_completed = true
        "pending"
      end

      def final_status
        finalize_pass
      end

      def only_pending_orders_remain?
        return false if remaining_scope_after_checkpoint.exists?

        # With no rows after the checkpoint, every remaining eligible row was
        # already attempted in this pass or was a pending row carried to the
        # checkpoint. No IDs are persisted; financial_synced_at is authoritative.
        true
      end

      def finish_log(status, error_message = nil)
        return unless log

        finished_at = status == "pending" ? nil : Time.current
        log.update!(
          status: status,
          finished_at: finished_at,
          duration_ms: finished_at && log.started_at ? ((finished_at - log.started_at) * 1000).round : nil,
          error_message: error_message,
          metadata: metadata_for_persistence
        )
      end

      def metadata_for_persistence
        metadata = (log.metadata || {}).dup
        metadata.delete("pending_order_ids")
        metadata.merge(metadata_snapshot)
      end

      def metadata_snapshot
        {
          "channel_credential_id" => channel_credential.id,
          "force" => force,
          "run_id" => run_id,
          "run_started_processed_count" => run_started_processed_count,
          "run_processed_count" => run_processed_count,
          "run_target_count" => run_target_count,
          "continuation_scheduled_at" => continuation_scheduled_at,
          "continuation_run_at" => continuation_run_at,
          "continuation_count" => continuation_count,
          "rate_limit_count" => rate_limit_count,
          "max_orders" => max_orders,
          "run_started_at" => run_started_at,
          "pass_count" => pass_count,
          "pass_completed" => pass_completed,
          "total_orders" => total_orders,
          "eligible_orders" => eligible_order_count,
          "remaining_orders" => remaining_orders,
          "processed_count" => processed_count,
          "synced_count" => synced_count,
          "skipped_count" => skipped_count,
          "pending_statement_count" => pending_statement_count,
          "error_count" => error_count,
          "last_order_id" => last_order_id,
          "last_batch_at" => last_batch_at,
          "pending_samples" => pending_samples,
          "error_samples" => error_samples
        }
      end

      def result_for(status)
        outcome = case status
        when "success" then :success
        when "pending" then :pending
        when "error" then :error
        else :skipped
        end
        result(outcome, log.error_message)
      end

      def result(outcome, error_message = nil)
        Result.new(
          outcome: outcome,
          error_message: error_message,
          metadata: metadata_snapshot
        )
      end

      def boolean_metadata(value)
        ActiveModel::Type::Boolean.new.cast(value)
      end

      def timestamp_from_metadata(value)
        return value if value.is_a?(Time)
        return if value.blank?

        Time.zone.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def error_count = @error_count
      def pending_statement_count = @pending_statement_count
      def total_orders = @total_orders
      def eligible_order_count = @eligible_orders
      def remaining_orders = @remaining_orders
      def processed_count = @processed_count
      def run_started_processed_count = @run_started_processed_count
      def run_processed_count = @run_processed_count
      def run_target_count = @run_target_count
      def continuation_scheduled_at = @continuation_scheduled_at
      def continuation_run_at = @continuation_run_at
      def continuation_count = @continuation_count
      def rate_limit_count = @rate_limit_count
      def remaining_capacity
        return if run_target_count.nil?

        run_target_count - run_processed_count
      end
      def synced_count = @synced_count
      def skipped_count = @skipped_count
      def last_order_id = @last_order_id
      def last_batch_at = @last_batch_at
      def run_started_at = @run_started_at
      def pass_count = @pass_count
      def pass_completed = @pass_completed
      def force = @force
      def lock_acquired = @lock_acquired
    end
  end
end
