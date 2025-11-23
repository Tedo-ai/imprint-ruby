class CreateOrders < ActiveRecord::Migration[8.0]
  def change
    create_table :orders do |t|
      t.string :email, null: false
      t.decimal :total, precision: 10, scale: 2, null: false
      t.string :status, default: "pending"
      t.text :items # JSON array of product IDs and quantities
      t.datetime :processed_at

      t.timestamps
    end

    add_index :orders, :status
    add_index :orders, :email
  end
end
