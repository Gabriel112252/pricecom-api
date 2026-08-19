class IdworksOrder < ApplicationRecord
  belongs_to :tenant
  belongs_to :integration

  validates :external_id, presence: true, uniqueness: { scope: :integration_id }
end
