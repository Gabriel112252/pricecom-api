Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check
  root to: proc { [200, { "Content-Type" => "text/plain" }, ["OK"]] }

  namespace :api do
    namespace :v1 do
      # Auth
      post "auth/login", to: "auth#login"
      get  "auth/me",    to: "auth#me"

      # Tenants
      resources :tenants, only: [ :index, :show, :create, :update ]

      # Channels
      resources :channels

      # Products
      resources :products, only: [ :index, :show, :update ] do
        member do
          get :turnover
          get   "kit_components", to: "kit_components#index"
          post  "kit_components", to: "kit_components#sync"
          patch "kit_components", to: "kit_components#sync"
        end
      end

      # Channel stock writes (admin only — the controller performs the
      # remote update before changing the local listing quantity).
      resources :channel_product_listings, only: [ :update ] do
        member do
          post :channel_action
        end
      end

      # Orders
      resources :orders, only: [ :index, :show, :create ] do
        collection do
          post :import
        end
      end

      # Pricing
      resources :pricing_rules do
        collection do
          post :calculate
        end
      end

      # Imports
      resources :imports, only: [ :index, :show, :create ]

      # Channel credentials + product sync (Yampi/Shopify/TikTok/Mercado
      # Livre/Shopee) — declared before `resources :integrations` below so
      # its `/integrations/:id` show route doesn't shadow `GET /integrations/channels`.
      scope "integrations" do
        get   "channels",         to: "channel_credentials#index"

        # idworks (ERP) and Pagar.me (financial gateway) — literal paths,
        # declared before the dynamic ":channel/connect" below so they
        # aren't swallowed by it (":channel" matches any string, including
        # "idworks"/"pagarme").
        post  "idworks/connect", to: "idworks#connect"
        post  "idworks/sync",    to: "idworks#sync"
        post  "pagarme/connect", to: "pagarme#connect"
        post  "pagarme/sync",    to: "pagarme#sync"

        get   "tiktok/authorize_url", to: "tiktok_oauth#authorize_url"
        get   "shopee/authorize_url", to: "shopee_oauth#authorize_url"

        post  ":channel/connect", to: "channel_credentials#connect"
        post  ":channel/sync",    to: "channel_credentials#sync"
        patch ":channel/role",    to: "channel_credentials#update_role"
        post  "yampi/backfill_orders", to: "channel_credentials#backfill_orders"
      end

      # Data source configs — which connected source feeds cost/freight/tax/
      # payment_reconciliation (see DataSourceConfig)
      get   "data_source_configs",             to: "data_source_configs#index"
      patch "data_source_configs/:data_type",  to: "data_source_configs#update"

      # Integrations
      resources :integrations

      # Integration Events (read-only)
      resources :integration_events, only: [ :index, :show ]

      # Integration Sync Logs (read-only)
      resources :integration_sync_logs, only: [ :index, :show ]

      # Audit Conflicts
      resources :audit_conflicts, only: [ :index, :show, :update ]

      # Financial Sources
      resources :financial_sources, only: [ :index, :show ]

      # Payment fee rules — cadastro manual das taxas negociadas com a
      # adquirente (Pagar.me), usado por PagarmePayableSyncService pra
      # validar a taxa cobrada contra a negociada.
      resources :payment_fee_rules, only: [ :index, :create, :update, :destroy ]

      # Stock alert rules + the alerts/events they raise — see
      # StockAlertRule/StockAlert and StockAlerts::EvaluationService.
      resources :stock_alert_rules, only: [ :index, :create, :update, :destroy ]
      resources :stock_alerts, only: [ :index ] do
        member do
          post :confirm
          post :dismiss
        end
      end

      # Financial Settlements
      resources :financial_settlements, only: [ :index, :show, :create ] do
        collection do
          post :import
          get  :template
        end
      end

      # Estoque — visão agregada produto x canal (ver StockOverviewController)
      get "stock_overview",     to: "stock_overview#index"
      get "stock_overview/:id", to: "stock_overview#show"

      # Dashboard
      get "dashboard/summary",   to: "dashboard#summary"
      get "dashboard/financial", to: "dashboard#financial"
      get "dashboard/freight_orders", to: "dashboard#freight_orders"
      get "dashboard/tiktok_orders", to: "dashboard#tiktok_orders"

      # TV Mode token (admin only) — regenerating invalidates the previous link
      get    "tv_token", to: "tv_tokens#show"
      post   "tv_token", to: "tv_tokens#create"
      delete "tv_token", to: "tv_tokens#destroy"

      # Integration Health
      get "integration_health", to: "integration_health#index"

      # Public OAuth callback from TikTok Shop. TikTok redirects the browser
      # with GET, while the generic webhook receiver below is POST-only.
      get "webhooks/tiktok", to: "tiktok_oauth#callback"

      # Public OAuth callback from Shopee (auth_partner redirect with
      # code + shop_id) — same GET-vs-POST split as the TikTok route above.
      get "webhooks/shopee", to: "shopee_oauth#callback"

      # Public webhook receiver — sem autenticação JWT
      post "webhooks/:provider", to: "webhooks#receive"

      # Public TV Mode dashboard — sem sessão de usuário, autenticado via token na URL
      get "tv/:token/summary", to: "tv#summary"
    end
  end
end
