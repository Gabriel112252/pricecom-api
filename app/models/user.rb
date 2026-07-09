class User < ApplicationRecord
  belongs_to :tenant
  has_secure_password

  validates :email, presence: true, uniqueness: { scope: :tenant_id }
  validates :name, presence: true

  scope :active, -> { where(active: true) }
end
