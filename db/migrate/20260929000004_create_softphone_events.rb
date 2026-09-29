class CreateSoftphoneEvents < ActiveRecord::Migration[7.1]
  # Call events pushed by the PBX, stored before anything is written into a conversation. Two reasons
  # to keep them: the client id's uniqueness makes the endpoint idempotent for retries, and a stored
  # payload is what lets the conversation-writing step be re-run or debugged after the fact.
  def change
    create_table :softphone_events do |t|
      t.references :account, null: false, foreign_key: true
      t.references :softphone_connection, null: false, foreign_key: true, index: false

      # the PBX's own id for the call: what makes a retry a no-op
      t.string :event_id, null: false
      t.string :kind, null: false

      t.jsonb :payload, null: false, default: {}
      t.datetime :received_at, null: false
      t.datetime :processed_at
      t.text :processing_error

      t.timestamps
    end

    add_index :softphone_events, %i[softphone_connection_id event_id], unique: true
    add_index :softphone_events, %i[account_id kind]
  end
end
