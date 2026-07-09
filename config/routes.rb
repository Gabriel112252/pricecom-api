Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  namespace :api do
    namespace :v1 do
      # Auth
      post "auth/login", to: "auth#login"
      get  "auth/me",    to: "auth#me"

      # Tenants
      resources :tenants, only: [:index, :show, :create, :update]

      # Channels
      resources :channels

      # Products
      resources :products

      # Orders
      resources :orders, only: [:index, :show, :create] do
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
      resources :imports, only: [:index, :show, :create]

      # Integrations
      resources :integrations

      # Integration Events (read-only)
      resources :integration_events, only: [:index, :show]

      # Integration Sync Logs (read-only)
      resources :integration_sync_logs, only: [:index, :show]

      # Audit Conflicts
      resources :audit_conflicts, only: [:index, :show, :update]

      # Dashboard
      get "dashboard/summary", to: "dashboard#summary"

      # Integration Health
      get "integration_health", to: "integration_health#index"

      # Public webhook receiver — sem autenticação JWT
      post "webhooks/:provider", to: "webhooks#receive"
    end
  end
end
