module Integrations
  module Tiktok
    # Syncs AffiliateCreator rows from every target collaboration plan on
    # this tenant's TikTok shop (Search Target Collaborations + Query
    # Target Collaboration Detail — see TiktokAdapter). Modeled after
    # FinancialBackfillService rather than PendingFinancialSyncService:
    # there is no existing queue of pending domain rows here, this is a
    # full periodic resync, closer in shape to a backfill.
    #
    # Checkpoint granularity is the target_collaborations PAGE, not the
    # individual collaboration — a rate limit mid-page re-fetches the whole
    # page on resume. AffiliateCreator upserts are idempotent by
    # creator_open_id, so the only cost of that simplification is some
    # redundant API calls, not duplicate/incorrect data. A typical shop has
    # a handful of target collaboration plans, so this trade-off favors
    # simplicity over the multi-level checkpoint FinancialBackfillService
    # needs for a much larger, order-scoped backfill.
    class AffiliateSyncService
      ACTION = "tiktok_affiliate_sync".freeze
      DEFAULT_SLEEP_SECONDS = Integer(ENV.fetch("TIKTOK_AFFILIATE_SYNC_SLEEP_MS", "250")) / 1000.0

      Result = Struct.new(:outcome, :error_message, :metadata, keyword_init: true) do
        def success? = outcome == :success
        def error? = outcome == :error
        def skipped? = outcome == :skipped
      end

      def self.call(channel_credential, sleep_seconds: DEFAULT_SLEEP_SECONDS, run_id: nil)
        new(channel_credential, sleep_seconds: sleep_seconds, run_id: run_id).call
      end

      def initialize(channel_credential, sleep_seconds:, run_id: nil)
        @channel_credential = channel_credential
        @tenant = channel_credential.tenant
        @sleep_seconds = sleep_seconds.to_f.positive? ? sleep_seconds.to_f : 0
        @run_id = run_id.to_s.presence || SecureRandom.uuid
        @adapter = Integrations::TiktokAdapter.new(channel_credential.credentials)
        @lock = AffiliateSyncLock.new(channel_credential)
        @creators_synced_count = 0
        @target_collaborations_processed_count = 0
        @rate_limit_count = 0
        @lock_acquired = false
      end

      def call
        @channel = tenant.channels.find_by(platform: "tiktok")
        return result(:skipped, "canal tiktok não encontrado") unless channel

        unless lock.acquire
          raise AffiliateSyncLock::LockBusyError, "sincronização de afiliados TikTok já está em execução"
        end

        @lock_acquired = true
        resume_or_start_log
        process_pages
        finish_log("success")
        persist_daily_snapshot
        result(:success)
      rescue Integrations::AuthenticationError => e
        channel_credential.update!(status: "error")
        finish_log("error", e.message)
        result(:error, e.message)
      rescue Integrations::RateLimitError => e
        @rate_limit_count += 1
        persist_checkpoint(error_message: "rate_limited: #{e.message}")
        raise
      rescue AffiliateSyncLock::LockLostError => e
        finish_log("error", e.message)
        raise
      ensure
        lock.release if lock_acquired
      end

      private

      attr_reader :channel_credential, :tenant, :adapter, :lock, :channel, :log,
        :sleep_seconds, :run_id, :lock_acquired

      def resume_or_start_log
        @log = resumable_log || IntegrationSyncLog.create!(
          tenant: tenant,
          direction: "inbound",
          action: ACTION,
          status: "pending",
          started_at: Time.current,
          metadata: metadata_snapshot
        )
        restore_checkpoint if log.persisted? && log.metadata.present?
      end

      def resumable_log
        IntegrationSyncLog
          .where(tenant: tenant, action: ACTION, status: "pending")
          .order(created_at: :desc)
          .find { |candidate| (candidate.metadata || {})["channel_credential_id"].to_s == channel_credential.id.to_s }
      end

      def restore_checkpoint
        metadata = log.metadata || {}
        @page_token = metadata["page_token"]
        @creators_synced_count = metadata["creators_synced_count"].to_i
        @target_collaborations_processed_count = metadata["target_collaborations_processed_count"].to_i
        @rate_limit_count = metadata["rate_limit_count"].to_i
      end

      def process_pages
        cursor = @page_token

        loop do
          renew_lock!
          data = adapter.fetch_target_collaborations(page_token: cursor)
          collaborations = Array(data["target_collaborations"])
          collaborations.each { |summary| process_collaboration(summary) }

          cursor = data["next_page_token"]
          @page_token = cursor
          persist_checkpoint
          break if collaborations.empty? || cursor.blank?
        end
      end

      def process_collaboration(summary)
        collaboration_id = summary["id"] || summary["target_collaboration_id"]
        return if collaboration_id.blank?

        detail = adapter.fetch_target_collaboration_detail(target_collaboration_id: collaboration_id)
        Array(detail["creators"]).each { |creator| upsert_creator(creator, collaboration_id) }
        @target_collaborations_processed_count += 1
        sleep(sleep_seconds) if sleep_seconds.positive?
      end

      def upsert_creator(creator, collaboration_id)
        open_id = creator["creator_open_id"]
        return if open_id.blank?

        record = channel.affiliate_creators.find_or_initialize_by(tenant: tenant, creator_open_id: open_id)
        record.assign_attributes(
          username: creator["username"],
          nickname: creator["nickname"],
          avatar_url: creator.dig("avatar", "url"),
          collaboration_status: creator["collaboration_status"],
          showcase_product_count: creator["showcase_product_count"].to_i,
          content_product_count: creator["content_product_count"].to_i,
          target_collaboration_id: collaboration_id,
          raw_payload: creator,
          synced_at: Time.current
        )
        record.save!
        @creators_synced_count += 1
      end

      def renew_lock!
        return if lock.renew

        raise AffiliateSyncLock::LockLostError, "lock da sincronização de afiliados TikTok foi perdido"
      end

      def persist_daily_snapshot
        creators = channel.affiliate_creators
        snapshot = AffiliateDailySnapshot.find_or_initialize_by(
          tenant: tenant, channel: channel, snapshot_date: Date.current
        )
        snapshot.update!(
          active_creators_count: creators.where(collaboration_status: "NORMAL").count,
          total_creators_count: creators.count,
          showcase_product_count_total: creators.sum(:showcase_product_count),
          content_product_count_total: creators.sum(:content_product_count)
        )
      end

      def persist_checkpoint(error_message: nil)
        return unless log

        log.update!(
          status: "pending",
          finished_at: nil,
          error_message: error_message,
          metadata: (log.metadata || {}).merge(metadata_snapshot)
        )
      end

      def finish_log(status, error_message = nil)
        return unless log

        log.update!(
          status: status,
          finished_at: Time.current,
          error_message: error_message,
          metadata: (log.metadata || {}).merge(metadata_snapshot)
        )
      end

      def metadata_snapshot
        {
          "channel_credential_id" => channel_credential.id,
          "run_id" => run_id,
          "page_token" => @page_token,
          "creators_synced_count" => creators_synced_count,
          "target_collaborations_processed_count" => target_collaborations_processed_count,
          "rate_limit_count" => rate_limit_count
        }
      end

      def result(outcome, error_message = nil)
        Result.new(outcome: outcome, error_message: error_message, metadata: metadata_snapshot)
      end

      def creators_synced_count = @creators_synced_count
      def target_collaborations_processed_count = @target_collaborations_processed_count
      def rate_limit_count = @rate_limit_count
    end
  end
end
