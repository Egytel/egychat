json.id connection.id
json.account_id connection.account_id
json.enabled connection.enabled
json.pbx_url connection.pbx_url
json.widget_path connection.widget_path
json.widget_url connection.widget_url
json.origin connection.origin
json.account_key connection.account_key

# never the value: two secrets can be told apart, neither can be reconstructed
json.secret_fingerprint connection.secret_fingerprint
json.secret_configured connection.secret.present?

# the one exception: the response that created it, and an explicit rotate
# (`reveal` is a jbuilder local, passed explicitly by every caller)
if reveal
  json.secret connection.secret
  json.notice 'store this now: it is not readable again'
end

json.tokens_verified_at connection.tokens_verified_at
json.events_verified_at connection.events_verified_at
json.last_error connection.last_error
json.created_at connection.created_at
json.updated_at connection.updated_at
