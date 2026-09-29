# Wiring between one Chatwoot account and the Laravel/Asterisk box its agents dial through.
#
# Exposed on the Platform API so an external provisioning app can fill it in, read it back and
# remove it. Two things to note about the shape of this endpoint:
#
#   * the secrets are WRITE-ONLY. They are generated here and returned in that one response, because
#     the other side has to be told them. Every later read returns only a fingerprint, so a leaked
#     platform token cannot harvest working secrets.
#   * a connection that does not exist reads as 404, not as an empty object: an operator asking
#     "is this account wired up?" deserves an unambiguous answer.
#
# Response shaping lives in the jbuilder partial; this controller only decides yes/no and status.
class Platform::Api::V1::SoftphoneConnectionsController < PlatformController
  before_action :set_account
  before_action :set_connection, only: [:show, :update, :destroy, :rotate]

  def show
    return render_not_found if @connection.nil?
  end

  def create
    return render_conflict if connection_exists?

    @connection = Softphone::Connection.new(permitted_params.merge(account_id: @account.id))
    issue_secrets(@connection)
    @connection.save!

    render :create, status: :created
  end

  def update
    return render_not_found if @connection.nil?

    @connection.assign_attributes(permitted_params)
    @connection.save!
  end

  def destroy
    return render_not_found if @connection.nil?

    @connection.destroy!
    head :ok
  end

  # A fresh secret, returned once like create: the recovery path when the other side has lost its
  # copy. Verification results are cleared because they no longer apply.
  def rotate
    return render_not_found if @connection.nil?

    issue_secrets(@connection)
    @connection.tokens_verified_at = nil
    @connection.events_verified_at = nil
    @connection.last_error = nil
    @connection.save!

    render :create, status: :created
  end

  private

  def set_account
    @account = Account.find(params[:account_id])
  end

  # PlatformController's own set_resource raises 'Overwrite this method your controller', and runs
  # for show/update/destroy; the resource it validates platform-app permission against is the
  # account we are wiring, not the connection row.
  def set_resource
    # PlatformController runs this before our own set_account, so it cannot rely on @account being
    # set yet. The resource it validates the platform app's permission against is the account.
    @account ||= Account.find(params[:account_id])
    @resource = @account
  end

  # create() has no set_connection before_action, so it must ask the database - an ivar guard
  # silently passed and then hit the unique index on account_id.
  def connection_exists?
    Softphone::Connection.exists?(account_id: @account.id)
  end

  def set_connection
    @connection = Softphone::Connection.find_by(account_id: @account.id)
  end

  # PlatformController deliberately leaves this to each controller ("Overwrite this method your
  # controller"). Note what is absent: the secrets. They are never accepted from the caller.
  def permitted_params
    # `secret` is accepted on write (a pairing has to match the box's value) but is never returned
    # by a read: see the jbuilder partial.
    params.permit(:enabled, :pbx_url, :widget_path, :account_key, :secret)
  end

  def issue_secrets(connection)
    connection.secret ||= Softphone::Connection.generate_secret
  end

  def render_conflict
    render json: { error: 'this account already has a softphone connection' }, status: :unprocessable_entity
  end

  def render_not_found
    render json: { error: 'this account has no softphone connection' }, status: :not_found
  end
end
