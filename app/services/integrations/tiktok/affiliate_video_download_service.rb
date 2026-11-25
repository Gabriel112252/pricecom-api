require "net/http"

module Integrations
  module Tiktok
    # Downloads one AffiliateVideo's file and attaches it as
    # AffiliateVideo#file (Active Storage — on disk in production, so the
    # storage/ folder must be a persistent volume).
    #
    # 1st source: play_url from Get Shop Videos Performance Details 202609
    # (TiktokAdapter#fetch_shop_video_details). It is TikTok's own signed,
    # short-lived URL, so it is fetched right before the download and never
    # stored.
    # 2nd source (fallback): yt-dlp on the public TikTok page, the same
    # downloader the testimonials import already uses
    # (Testimonials::TiktokVideoDownloader), for when the API returns no
    # play_url for that video.
    #
    # Never raises for a failed download — the row ends up "failed" with the
    # reason in download_error, so the MCP tool can show it. The exception
    # is a rate limit on the API call, re-raised for the job to retry later.
    class AffiliateVideoDownloadService
      MAX_BYTES = Integer(ENV.fetch("TIKTOK_AFFILIATE_VIDEO_MAX_MB", "500")) * 1024 * 1024
      OPEN_TIMEOUT = 15
      READ_TIMEOUT = 120
      MAX_REDIRECTS = 3
      DETAILS_LOOKBACK_DAYS = Integrations::TiktokAdapter::SHOP_VIDEOS_MAX_RANGE_DAYS
      USER_AGENT = "Mozilla/5.0 (compatible; Pricecom/1.0)".freeze

      class DownloadError < StandardError; end

      Result = Struct.new(:outcome, :error_message, :source, keyword_init: true) do
        def success? = outcome == :success
        def error? = outcome == :error
        def skipped? = outcome == :skipped
      end

      def self.call(video)
        new(video).call
      end

      def initialize(video)
        @video = video
        @errors = []
        @tempfile = nil
      end

      def call
        return Result.new(outcome: :skipped, source: "already_downloaded") if video.downloaded?

        video.update!(download_status: "downloading", download_error: nil)
        downloaded = download_from_play_url || download_with_yt_dlp
        raise DownloadError, (errors.join(" | ").presence || "nenhuma fonte de download disponível") unless downloaded

        io, content_type, source = downloaded
        video.file.attach(io: io, filename: filename_for(content_type), content_type: content_type)
        video.update!(download_status: "downloaded", downloaded_at: Time.current, download_error: nil)
        Result.new(outcome: :success, source: source)
      rescue Integrations::RateLimitError
        video.update_columns(download_status: "pending", updated_at: Time.current)
        raise
      rescue StandardError => e
        video.update_columns(download_status: "failed", download_error: e.message.to_s.truncate(1000), updated_at: Time.current)
        Result.new(outcome: :error, error_message: e.message)
      ensure
        @tempfile&.close!
      end

      private

      attr_reader :video, :errors

      def download_from_play_url
        credential = tiktok_credential
        unless credential
          errors << "TikTok Shop não está conectado"
          return nil
        end

        entry = fetch_details_entry(credential)
        return nil unless entry

        meta = entry["video"].is_a?(Hash) ? entry["video"] : {}
        remember_metadata(meta)
        play_url = meta["play_url"].to_s.strip
        if play_url.blank?
          errors << "a API não devolveu play_url para este vídeo"
          return nil
        end

        tempfile, content_type = http_download(play_url)
        [ tempfile, content_type, "play_url" ]
      rescue Integrations::RateLimitError
        raise
      rescue StandardError => e
        errors << "play_url: #{e.message}"
        nil
      end

      def fetch_details_entry(credential)
        adapter = Integrations::TiktokAdapter.new(credential.credentials)
        date_from, date_to = details_window
        entries = adapter.fetch_shop_video_details(video_ids: [ video.video_id ], date_from: date_from, date_to: date_to)
        entry = entries.find { |e| e["video_id"].to_s == video.video_id || e.dig("video", "id").to_s == video.video_id }

        if entry.nil?
          errors << "a API não devolveu este vídeo"
        elsif entry["error"].is_a?(Hash) && entry["error"]["code"].present? && !entry["video"].is_a?(Hash)
          errors << "a API recusou o vídeo (#{entry.dig("error", "code")}: #{entry.dig("error", "message")})"
          entry = nil
        end
        entry
      end

      # The window the sync last saw this video in (metrics["window"]). One
      # details call covers at most DETAILS_LOOKBACK_DAYS, so a video only seen
      # in an older window (31-60 days back) is asked for in that window rather
      # than in the last 30 days, where it may have no data. Falls back to the
      # last DETAILS_LOOKBACK_DAYS days.
      def details_window
        today = Date.current
        window = video.metrics.is_a?(Hash) && video.metrics["window"].is_a?(Hash) ? video.metrics["window"] : {}
        from = parse_date(window["from"])
        to = parse_date(window["to"])
        return [ today - (DETAILS_LOOKBACK_DAYS - 1), today ] unless from && to && from <= to && to <= today

        [ [ from, to - (DETAILS_LOOKBACK_DAYS - 1) ].max, to ]
      end

      def parse_date(value)
        Date.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end

      def remember_metadata(meta)
        changes = {}
        changes[:thumbnail_url] = meta["thumbnail_url"] if meta["thumbnail_url"].present?
        changes[:duration_seconds] = meta["duration"].to_i if video.duration_seconds.blank? && meta["duration"].present?
        changes[:title] = meta["title"] if video.title.blank? && meta["title"].present?
        video.update_columns(changes.merge(updated_at: Time.current)) if changes.any?
      end

      def tiktok_credential
        credential = video.channel_credential
        return credential if credential&.status == "active"

        video.tenant.channel_credentials.active.where(channel: "tiktok").order(:id).first
      end

      # Streams into a Tempfile (videos can be large), following up to
      # MAX_REDIRECTS redirects and aborting past MAX_BYTES.
      def http_download(url, redirects_left = MAX_REDIRECTS)
        uri = URI.parse(url)
        raise DownloadError, "play_url inválida" unless uri.is_a?(URI::HTTP) && uri.host.present?

        tempfile = Tempfile.new([ "affiliate-video-", ".mp4" ], binmode: true)
        redirect_to = nil
        content_type = nil

        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
          request = Net::HTTP::Get.new(uri)
          request["User-Agent"] = USER_AGENT
          http.request(request) do |response|
            case response
            when Net::HTTPRedirection
              redirect_to = response["location"].to_s
            when Net::HTTPSuccess
              content_type = response.content_type
              copy_body(response, tempfile)
            else
              raise DownloadError, "play_url respondeu HTTP #{response.code}"
            end
          end
        end

        if redirect_to
          tempfile.close!
          raise DownloadError, "redirecionamentos demais" if redirects_left <= 0 || redirect_to.blank?

          return http_download(URI.join(url, redirect_to).to_s, redirects_left - 1)
        end

        tempfile.rewind
        raise DownloadError, "play_url devolveu um arquivo vazio" if tempfile.size.zero?

        @tempfile = tempfile
        [ tempfile, normalize_content_type(content_type) ]
      rescue StandardError
        tempfile&.close! unless tempfile.nil? || tempfile.equal?(@tempfile)
        raise
      end

      def copy_body(response, tempfile)
        bytes = 0
        response.read_body do |chunk|
          bytes += chunk.bytesize
          raise DownloadError, "vídeo maior que o limite de #{MAX_BYTES / 1.megabyte} MB" if bytes > MAX_BYTES

          tempfile.write(chunk)
        end
      end

      def download_with_yt_dlp
        url = video.tiktok_url
        unless url
          errors << "sem o @ da criadora para montar o link do TikTok"
          return nil
        end

        result = Testimonials::TiktokVideoDownloader.call(url)
        unless result[:success]
          errors << "yt-dlp: #{result[:error]}"
          return nil
        end

        [ StringIO.new(result[:bytes]), normalize_content_type(result[:content_type]), "yt_dlp" ]
      end

      def normalize_content_type(content_type)
        type = content_type.to_s.split(";").first.to_s.strip.downcase
        type.start_with?("video/") ? type : "video/mp4"
      end

      def filename_for(content_type)
        handle = video.username.to_s.parameterize.presence || "afiliada"
        "#{handle}-#{video.video_id}#{extension_for(content_type)}"
      end

      def extension_for(content_type)
        case content_type
        when "video/webm" then ".webm"
        when "video/quicktime" then ".mov"
        else ".mp4"
        end
      end
    end
  end
end
