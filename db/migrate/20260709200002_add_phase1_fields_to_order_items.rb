class AddPhase1FieldsToOrderItems < ActiveRecord::Migration[7.2]
  def change
    add_column :order_items, :is_gift,      :boolean, default: false, null: false
    add_column :order_items, :nf_unit_price, :decimal, precision: 10, scale: 2, default: "0.0", null: false
  end
end
