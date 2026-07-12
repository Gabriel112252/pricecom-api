class AddYampiOrdersPollingToChannelCredentials < ActiveRecord::Migration[7.2]
  def change
    add_column :channel_credentials, :orders_sync_cursor_at, :datetime
    add_column :channel_credentials, :polling_enabled, :boolean, null: false, default: false
  end
end
