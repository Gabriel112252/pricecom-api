class AffiliateVideo < ApplicationRecord
  DOWNLOAD_STATUSES = %w[pending queued downloading downloaded failed].freeze
  # A queued/downloading row older than this is treated as abandoned (worker
  # restarted mid-download, job lost) and becomes eligible to be queued again.
  STALE_DOWNLOAD_AFTER = 1.hour

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
