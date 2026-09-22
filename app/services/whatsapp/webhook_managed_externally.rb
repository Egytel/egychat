module Whatsapp::WebhookManagedExternally
  def webhook_managed_externally?
    GlobalConfigService.load('WHATSAPP_WEBHOOK_MANAGED_EXTERNALLY', 'false').to_s != 'false'
  end
end
