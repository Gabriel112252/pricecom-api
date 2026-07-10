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
        post  ":channel/connect", to: "channel_credentials#connect"
        post  ":channel/sync",    to: "channel_credentials#sync"
        patch ":channel/role",    to: "channel_credentials#update_role"
      end

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

      # Financial Settlements
      resources :financial_settlements, only: [ :index, :show, :create ] do
        collection do
          post :import
          get  :template
        end
      end

      # Dashboard
      get "dashboard/summary",   to: "dashboard#summary"
      get "dashboard/financial", to: "dashboard#financial"

      # TV Mode token (admin only) — regenerating invalidates the previous link
      get    "tv_token", to: "tv_tokens#show"
      post   "tv_token", to: "tv_tokens#create"
      delete "tv_token", to: "tv_tokens#destroy"

      # Integration Health
      get "integration_health", to: "integration_health#index"

      # Public webhook receiver — sem autenticação JWT
      post "webhooks/:provider", to: "webhooks#receive"

      # Public TV Mode dashboard — sem sessão de usuário, autenticado via token na URL
      get "tv/:token/summary", to: "tv#summary"
    end
  end
end
