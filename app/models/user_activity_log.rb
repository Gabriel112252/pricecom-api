class UserActivityLog < ApplicationRecord
  belongs_to :tenant
  belongs_to :user, optional: true

  ACTIONS = %w[
    login.success
    login.failed
    user.created
    user.updated
    user.role_changed
    user.deactivated
    user.reactivated
    channel_credential.updated
    channel_sync.triggered
  ].freeze

  validates :action, presence: true, inclusion: { in: ACTIONS }

  scope :recent, -> { order(created_at: :desc) }
  scope :by_action, ->(action) { where(action: action) }
  scope :by_user, ->(user_id) { where(user_id: user_id) }
end
