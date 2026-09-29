class CollapseSoftphoneConnectionSecret < ActiveRecord::Migration[7.1]
  # One secret per pairing, as agreed: it authenticates Chatwoot to the Laravel box, and the box uses
  # the same value to sign the call events it posts back. The second column was never referenced by
  # anything, and the table was empty when this ran.
  def change
    rename_column :softphone_connections, :token_secret_ciphertext, :secret_ciphertext
    remove_column :softphone_connections, :event_secret_ciphertext, :text
  end
end
