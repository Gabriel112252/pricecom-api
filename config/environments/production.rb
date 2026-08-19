require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot. This eager loads most of Rails and your application in memory,
  # allowing both threaded web servers and those relying on copy on write to perform better.
  # Rake tasks automatically ignore this option for performance.
  config.eager_load = true

  # Full error reports are disabled and caching is turned on.
  config.consider_all_requests_local = false

  # Ensures that a master key has been made available in ENV["RAILS_MASTER_KEY"], config/master.key, or an environment
  # key such as RAILS_MASTER_KEY. This key is used to decrypt credentials and other encrypted files.
  # config.require_master_key = true

  # Disable serving static files from `public/`, relying on NGINX/Apache to do so instead.
  # config.public_file_server.enabled = false

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Specifies the header that your server uses for sending files.
  # config.action_dispatch.x_sendfile_header = "X-Sendfile" # for Apache
  # config.action_dispatch.x_sendfile_header = "X-Accel-Redirect" # for NGINX

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local

  # Public domain used to build absolute URLs (e.g. rails_blob_url for
  # testimonial media). Must NOT come from the incoming request — internal
  # calls (health checks, curl from inside the container) hit the app as
  # "localhost", which would otherwise get baked into URLs shipped to
  # customers' browsers. Same fallback host already used for the frontend
  # in Api::V1::TiktokOauthController#frontend_base_url.
  app_host = ENV.fetch("APP_HOST", "https://pricecom-pricecom-api.dzxtro.easypanel.host")
  Rails.application.routes.default_url_options[:host] = app_host

  # Mount Action Cable outside main process or domain.
  # config.action_cable.mount_path = nil
  # config.action_cable.url = "wss://example.com/cable"
  # config.action_cable.allowed_request_origins = [ "http://example.com", /.*\.example.*/ ]

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  # Can be used together with config.force_ssl for Strict-Transport-Security and secure cookies.
  config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint.
  config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT by default
  config.logger = ActiveSupport::Logger.new(STDOUT)
    .tap  { |logger| logger.formatter = ::Logger::Formatter.new }
    .then { |logger| ActiveSupport::TaggedLogging.new(logger) }

  # Prepend all log lines with the following tags.
  config.log_tags = [ :request_id ]

  # "info" includes generic and useful information about system operation, but avoids logging too much
  # information to avoid inadvertent exposure of personally identifiable information (PII). If you
  # want to log everything, set the level to "debug".
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Cache curto do dashboard. MemoryStore evita dependência nova e já tira
  # recálculos repetidos das queries mais pesadas. É limitado para não deixar
  # o processo crescer sem controle; se o app passar a ter vários workers/
  # réplicas, o próximo passo é trocar por um cache Redis compartilhado.
  config.cache_store = :memory_store, { size: 64.megabytes }

  # Use a real queuing backend for Active Job (and separate queues per environment).
  config.active_job.queue_adapter = :sidekiq
  # config.active_job.queue_name_prefix = "pricecom_production"

  # Disable caching for Action Mailer templates even if Action Controller
  # caching is enabled.
  config.action_mailer.perform_caching = false

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false

  # E-mail transacional — hoje só UserMailer#invitation_email. Host é o
  # FRONTEND_URL (não app_host acima) porque o único link que um mailer
  # gera hoje aponta pro SPA (tela de aceitar convite), nunca pra API.
  config.action_mailer.default_url_options = { host: ENV["FRONTEND_URL"] }

  # SMTP genérico por env var — não amarrado a um provider específico, pra
  # não precisar mexer em código se trocar de Resend pra outro no futuro.
  # Hoje configurado com Resend (ver .env.example): smtp.resend.com:587,
  # user_name literal "resend", password = API key do Resend.
  # Se as env vars estiverem ausentes (SMTP não configurado ainda),
  # UserMailer#invitation_email detecta isso e pula o envio com um warning
  # no log, sem derrubar a request que criou o usuário — ver
  # UserMailer#smtp_configured?.
  config.action_mailer.smtp_settings = {
    address:              ENV["SMTP_ADDRESS"],
    port:                 ENV.fetch("SMTP_PORT", 587).to_i,
    domain:               ENV["SMTP_DOMAIN"],
    user_name:            ENV["SMTP_USERNAME"],
    password:             ENV["SMTP_PASSWORD"],
    authentication:       "plain",
    enable_starttls_auto: true
  }
  config.action_mailer.delivery_method = :smtp

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Enable DNS rebinding protection and other `Host` header attacks.
  # config.hosts = [
  #   "example.com",     # Allow requests from example.com
  #   /.*\.example.*/    # Allow requests from subdomains like www.example.com
  # ]
  # Skip DNS rebinding protection for the default health check endpoint.
  # config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
