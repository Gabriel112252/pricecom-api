class AddCartsSyncCursorAtToChannelCredentials < ActiveRecord::Migration[7.2]
  def change
    add_column :channel_credentials, :carts_sync_cursor_at, :datetime
  end
end
