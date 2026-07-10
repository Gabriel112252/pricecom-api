class AddTvTokenToTenants < ActiveRecord::Migration[7.2]
  def change
    add_column :tenants, :tv_token, :string
    add_index :tenants, :tv_token, unique: true
  end
end
