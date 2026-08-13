class AddMcpApiKeyToUsers < ActiveRecord::Migration[7.2]
  def change
    add_column :users, :mcp_api_key, :string
    add_index :users, :mcp_api_key, unique: true
  end
end
