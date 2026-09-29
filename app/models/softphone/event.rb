# A call event the PBX pushed to us.
#
# One row per call as the box knows it (event_id is the box's own id), which is what makes the
# receiving endpoint idempotent: a retry finds the row and reports a duplicate instead of logging the
# call twice. The payload is kept verbatim so the conversation-writing step can be re-run.
class Softphone::Event < ApplicationRecord
  self.table_name = 'softphone_events'

  # The kinds we accept. Anything else is refused rather than stored: the endpoint is public, so it
  # should not be a place to park arbitrary JSON.
  KINDS = %w[call.completed call.missed call.started].freeze

  belongs_to :account
  belongs_to :connection, class_name: 'Softphone::Connection', foreign_key: :softphone_connection_id,
                          inverse_of: false

  validates :event_id, :kind, :received_at, presence: true
  validates :kind, inclusion: { in: KINDS }

  scope :unprocessed, -> { where(processed_at: nil) }

  # Fields we read out of the payload. Documented here because the contract lives between two boxes.
  #   call_id     - the box's call identifier (also the event_id)
  #   direction   - inbound | outbound
  #   number      - the other party's number: the join key against contacts
  #   agent_email - who handled it
  #   started_at / duration_seconds / recording_url - what the conversation bubble shows
  def number
    payload['number'].presence
  end

  def direction
    payload['direction'].presence
  end

  def duration_seconds
    payload['duration_seconds'].to_i
  end

  def agent_email
    payload['agent_email'].presence
  end
end
