class AffiliateVideo < ApplicationRecord
  DOWNLOAD_STATUSES = %w[pending queued downloading downloaded failed].freeze
  # A queued/downloading row older than this is treated as abandoned (worker
  # restarted mid-download, job lost) and becomes eligible to be queued again.
  STALE_DOWNLOAD_AFTER = 1.hour
  # Orderings over the list endpoint's metrics as stored: "gmv" is
  # {"amount" => "103143.37", "currency" => "BRL"}, "views" a number. A
  # missing or non-numeric value sorts last.
  GMV_SQL = "CASE WHEN affiliate_videos.metrics -> 'gmv' ->> 'amount' ~ '^[0-9]+(\\.[0-9]+)?$' " \
    "THEN (affiliate_videos.metrics -> 'gmv' ->> 'amount')::numeric END".freeze
  VIEWS_SQL = "CASE WHEN affiliate_videos.metrics ->> 'views' ~ '^[0-9]+$' " \
    "THEN (affiliate_videos.metrics ->> 'views')::numeric END".freeze
  NEWEST_FIRST_SQL = "affiliate_videos.posted_at DESC NULLS LAST, affiliate_videos.id DESC".freeze

  belongs_to :tenant
  belongs_to :channel
  belongs_to :affiliate_creator, optional: true
  belongs_to :channel_credential, optional: true

  has_one_attached :file

  validates :video_id, presence: true, uniqueness: { scope: [ :tenant_id, :channel_id ] }
  validates :download_status, inclusion: { in: DOWNLOAD_STATUSES }

  scope :downloaded, -> { where(download_status: "downloaded") }
  scope :awaiting_download, lambda {
    where(download_status: "pending")
      .or(where(download_status: %w[queued downloading]).where(updated_at: ...STALE_DOWNLOAD_AFTER.ago))
  }
  scope :newest_first, -> { order(Arel.sql(NEWEST_FIRST_SQL)) }
  scope :top_gmv_first, -> { order(Arel.sql("#{GMV_SQL} DESC NULLS LAST, #{NEWEST_FIRST_SQL}")) }
  scope :most_viewed_first, -> { order(Arel.sql("#{VIEWS_SQL} DESC NULLS LAST, #{NEWEST_FIRST_SQL}")) }

  def tiktok_url
    return nil if username.blank? || video_id.blank?

    "https://www.tiktok.com/@#{username}/video/#{video_id}"
  end

  def downloaded?
    download_status == "downloaded" && file.attached?
  end

  def download_in_progress?
    %w[queued downloading].include?(download_status) && updated_at.present? && updated_at > STALE_DOWNLOAD_AFTER.ago
  end
end
