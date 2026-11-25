module Integrations
  module Tiktok
    # Pulls the videos affiliate creators posted for this tenant's TikTok
    # shop (Get Shop Video Performance List 202605, account_type
    # AFFILIATE_ACCOUNTS — see TiktokAdapter#fetch_shop_videos) and keeps the
    # ones whose creator is in a target collaboration ("colaboração
    # direcionada") as AffiliateVideo rows. "In a target collaboration" means
    # an AffiliateCreator row with a target_collaboration_id, i.e. what
    # AffiliateSyncService last synced — run that first (AffiliateVideoSyncJob
    # does) or the filter has nothing to match against.
    #
    # The API caps each call at 60 days, so days_back is walked in 60-day
    # windows, newest first. A video showing up in more than one window keeps
    # the metrics of the newest window it appeared in (first one seen in the
    # run).
    #
    # New videos are queued for download (AffiliateVideoDownloadJob) unless
    # TIKTOK_AFFILIATE_VIDEO_AUTO_DOWNLOAD=false, at most
    # MAX_DOWNLOADS_ENQUEUED_PER_RUN per run so a first sync over a big
    # backlog doesn't fill the disk in one go; the rest stay pending and go
    # out on the next runs (or on demand, via the baixar_video_afiliada MCP
    # tool).
    class AffiliateVideoSyncService
      ACTION = "tiktok_affiliate_video_sync".freeze
      ACCOUNT_TYPE = "AFFILIATE_ACCOUNTS".freeze
      DEFAULT_DAYS_BACK = 60
      MAX_DAYS_BACK = 365
      WINDOW_DAYS = Integrations::TiktokAdapter::SHOP_VIDEOS_MAX_RANGE_DAYS
      # Safety net against a next_page_token that never ends — 50 pages of
      # 100 is 5k videos in one 60-day window, far more than any real shop.
      MAX_PAGES_PER_WINDOW = 50
      MAX_DOWNLOADS_ENQUEUED_PER_RUN = Integer(ENV.fetch("TIKTOK_AFFILIATE_VIDEO_DOWNLOADS_PER_RUN", "50"))
      METRIC_KEYS = %w[
        views likes comments shares new_followers items_sold sku_orders avg_customers
        product_clicks product_impressions click_through_rate video_finish_rate
        gmv attributed_gmv indirect_gmv gpm
      ].freeze

      Result = Struct.new(:outcome, :error_message, :metadata, keyword_init: true) do
        def success? = outcome == :success
        def error? = outcome == :error
        def skipped? = outcome == :skipped
      end

      def self.call(channel_credential, days_back: DEFAULT_DAYS_BACK, today: Date.current, auto_download: auto_download?)
        new(channel_credential, days_back: days_back, today: today, auto_download: auto_download).call
      end

      def self.auto_download?
        ENV.fetch("TIKTOK_AFFILIATE_VIDEO_AUTO_DOWNLOAD", "true") != "false"
      end

      def initialize(channel_credential, days_back:, today:, auto_download:)
        @channel_credential = channel_credential
        @tenant = channel_credential.tenant
        @days_back = days_back.to_i.clamp(1, MAX_DAYS_BACK)
        @today = today.to_date
        @auto_download = auto_download
        @adapter = Integrations::TiktokAdapter.new(channel_credential.credentials)
        @seen_video_ids = Set.new
        @counts = Hash.new(0)
      end

      def call
        @channel = tenant.channels.find_by(platform: "tiktok")
        return result(:skipped, "canal tiktok não encontrado") unless channel

        load_target_creators
        return result(:skipped, "nenhuma criadora com colaboração direcionada sincronizada ainda") if creators_by_open_id.empty?

        start_log
        each_window { |from, to| sync_window(from, to) }
        enqueue_downloads if auto_download
        finish_log("success")
        result(:success)
      rescue Integrations::AuthenticationError => e
        # Unlike the order/affiliate syncs, a missing analytics scope must not
        # flip the whole credential to "error" — orders keep syncing fine
        # without this optional feature. The log carries the scope hint.
        finish_log("error", e.message)
        result(:error, e.message)
      rescue Integrations::RateLimitError => e
        finish_log("error", "rate_limited: #{e.message}")
        raise
      rescue StandardError => e
        finish_log("error", e.message)
        raise
      end

      private

      attr_reader :channel_credential, :tenant, :adapter, :channel, :log, :days_back, :today,
        :auto_download, :creators_by_open_id, :creators_by_username, :counts

      def load_target_creators
        creators = channel.affiliate_creators.where.not(target_collaboration_id: [ nil, "" ]).to_a
        @creators_by_open_id = creators.index_by(&:creator_open_id)
        @creators_by_username = creators.select { |c| c.username.present? }.index_by { |c| c.username.downcase }
      end

      # [from, to] pairs (both inclusive), newest first, each at most
      # WINDOW_DAYS long, together covering the last days_back days.
      def each_window
        oldest = today - (days_back - 1)
        to = today
        while to >= oldest
          from = [ to - (WINDOW_DAYS - 1), oldest ].max
          yield from, to
          to = from - 1
        end
      end

      def sync_window(from, to)
        page_token = nil
        MAX_PAGES_PER_WINDOW.times do
          data = adapter.fetch_shop_videos(date_from: from, date_to: to, account_type: ACCOUNT_TYPE, page_token: page_token)
          Array(data["videos"]).each { |raw| process_video(raw, from, to) }
          counts["pages"] += 1

          page_token = data["next_page_token"].presence
          break if page_token.nil?
        end
      end

      def process_video(raw, window_from, window_to)
        video_id = raw["id"].to_s.strip
        return if video_id.blank?

        counts["videos_seen"] += 1
        return if @seen_video_ids.include?(video_id)

        @seen_video_ids << video_id
        creator_payload = raw["creator"].is_a?(Hash) ? raw["creator"] : {}
        creator = matching_creator(creator_payload, raw)
        return unless creator

        record = channel.affiliate_videos.find_or_initialize_by(tenant: tenant, video_id: video_id)
        counts[record.new_record? ? "videos_created" : "videos_updated"] += 1
        record.assign_attributes(
          affiliate_creator: creator,
          channel_credential: channel_credential,
          creator_open_id: creator_payload["open_id"].presence || creator.creator_open_id,
          username: creator_payload["user_name"].presence || raw["username"].presence || creator.username,
          nickname: creator_payload["nick_name"].presence || creator.nickname,
          author_type: creator_payload["author_type"],
          title: raw["title"],
          duration_seconds: raw["duration"].presence&.to_i,
          posted_at: parse_post_time(raw["video_post_time"]) || record.posted_at,
          products: Array(raw["products"]).filter_map { |p| p.slice("id", "name") if p.is_a?(Hash) },
          metrics: raw.slice(*METRIC_KEYS).merge("window" => { "from" => window_from.iso8601, "to" => window_to.iso8601 }),
          raw_payload: raw,
          synced_at: Time.current
        )
        record.save!
      end

      def matching_creator(creator_payload, raw)
        open_id = creator_payload["open_id"].to_s
        username = (creator_payload["user_name"].presence || raw["username"]).to_s.downcase
        creators_by_open_id[open_id].presence || creators_by_username[username]
      end

      # The list endpoint sends "YYYY-MM-DD HH:MM:SS" (shop timezone, no
      # offset); the details endpoint sends unix seconds as a string.
      def parse_post_time(value)
        text = value.to_s.strip
        return nil if text.blank?
        return Time.zone.at(text.to_i) if text.match?(/\A\d+\z/)

        Time.zone.parse(text)
      rescue ArgumentError
        nil
      end

      def enqueue_downloads
        channel.affiliate_videos.where(tenant: tenant).awaiting_download
          .order(posted_at: :desc).limit(MAX_DOWNLOADS_ENQUEUED_PER_RUN).each do |video|
          video.update!(download_status: "queued", download_error: nil)
          AffiliateVideoDownloadJob.perform_later(video.id)
          counts["downloads_enqueued"] += 1
        end
      end

      def start_log
        @log = IntegrationSyncLog.create!(
          tenant: tenant,
          channel_credential: channel_credential,
          direction: "inbound",
          action: ACTION,
          status: "pending",
          started_at: Time.current,
          metadata: metadata_snapshot
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
          "days_back" => days_back,
          "target_creators_count" => creators_by_open_id ? creators_by_open_id.size : 0
        }.merge(counts.transform_keys(&:to_s))
      end

      def result(outcome, error_message = nil)
        Result.new(outcome: outcome, error_message: error_message, metadata: metadata_snapshot)
      end
    end
  end
end
