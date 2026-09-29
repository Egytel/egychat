class CreateSoftphoneConnections < ActiveRecord::Migration[7.1]
  # One row per account: which Laravel/Asterisk box this account's agents dial through, and the
  # two secrets that authenticate the two directions. Kept out of installation_configs because
  # installation configs are global - each tenant can point at its own PBX.
  def change
    create_table :softphone_connections do |t|
      t.references :account, null: false, foreign_key: true, index: { unique: true }

      t.boolean :enabled, null: false, default: true

      # where the softphone page lives, e.g. https://997.c6.egytelecoms.com
      t.string :pbx_url, null: false
      t.string :widget_path, null: false, default: '/dashboard/phone-widget'

      # how this box identifies which Chatwoot account it belongs to (shown on both sides)
      t.string :account_key, null: false

      # direction A: Chatwoot signs the agent's session token, the PBX verifies it
      t.text :token_secret_ciphertext
      # direction B: the PBX signs its call events, Chatwoot verifies them
      t.text :event_secret_ciphertext

      # last time each direction was proven live, and what went wrong if it was not
      t.datetime :tokens_verified_at
      t.datetime :events_verified_at
      t.text :last_error

      t.timestamps
    end
  end
end
