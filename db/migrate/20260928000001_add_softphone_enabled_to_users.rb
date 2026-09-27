class AddSoftphoneEnabledToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :softphone_enabled, :boolean, default: false, null: false
  end
end
