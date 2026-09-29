# Receives call events from the PBX.
#
# Public by necessity: the box has no Chatwoot user session, so this endpoint is authenticated by the
# signature instead - HMAC-SHA256 over "<timestamp>.<raw body>" with the account's pairing secret,
# sent as `X-Hatif-Signature: t=<unix>,v1=<hex>`. Requests older than a few minutes are refused so a
# captured request cannot be replayed later, and each call id can only be stored once.
#
# Nothing here writes into a conversation yet: the event is stored, and the conversation side reads
# from that store. Keeps the public surface small and the domain logic re-runnable.
class Softphone::EventsController < ActionController::API
  SIGNATURE_HEADER = 'X-Hatif-Signature'.freeze
  MAX_SKEW = 5.minutes

  def create
    connection = connection_for(request)
    return render_error('unknown_pair', :unauthorized) unless connection&.usable?
    return render_error('bad_signature', :unauthorized) unless signature_valid?(request, connection)
    return render_error('stale_timestamp', :unauthorized) unless timestamp_fresh?(request)

    event = record_event(connection)

    render json: {
      ok: true,
      event_id: event.event_id,
      duplicate: !event.previously_new_record?
    }, status: :ok
  rescue ActionController::ParameterMissing, JSON::ParserError
    render_error('bad_payload', :unprocessable_entity)
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.to_sentence, :unprocessable_entity)
  end

  private

  # The pairing is identified by the account key in the header, not from the body: the body is the
  # part we are verifying.
  def connection_for(request)
    Softphone::Connection.find_by(account_key: request.headers['X-Hatif-Account-Key'].to_s.strip)
  end

  def signature_valid?(request, connection)
    provided = request.headers[SIGNATURE_HEADER].to_s
    timestamp = provided[/t=(\d+)/, 1]
    return false if timestamp.blank? || connection.secret.blank?

    expected = OpenSSL::HMAC.hexdigest('SHA256', connection.secret, "#{timestamp}.#{request.raw_post}")

    provided[/v1=([0-9a-f]+)/, 1].to_s.then do |given|
      return false if given.length != expected.length

      ActiveSupport::SecurityUtils.secure_compare(given, expected)
    end
  end

  def timestamp_fresh?(request)
    timestamp = request.headers[SIGNATURE_HEADER].to_s[/t=(\d+)/, 1].to_i

    (Time.current.to_i - timestamp).abs <= MAX_SKEW.to_i
  end

  def record_event(connection)
    body = JSON.parse(request.raw_post.presence || '{}')
    event_id = (body['event_id'].presence || body.dig('call', 'id').presence).to_s

    raise ActionController::ParameterMissing, 'event_id' if event_id.blank?

    # find_or_create_by keeps the endpoint idempotent: a retry returns the same row and the caller
    # learns it was a duplicate.
    Softphone::Event.find_or_create_by!(softphone_connection_id: connection.id, event_id: event_id) do |event|
      event.account_id = connection.account_id
      event.kind = event_kind(body)
      event.payload = event_payload(body)
      event.received_at = Time.current
    end
  end

  def event_kind(body)
    # the model's inclusion validation is what refuses anything unknown (422 rather than stored)
    (body['kind'].presence || 'call.completed').to_s
  end

  # The call's own fields are lifted to the top of the stored payload, so readers do not have to know
  # whether the box nested them under "call".
  def event_payload(body)
    call = body['call']

    call.is_a?(Hash) ? call.merge(body.except('call')) : body
  end

  def render_error(message, status)
    render json: { ok: false, message: message }, status: status
  end
end
