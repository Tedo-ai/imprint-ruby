Rails.application.routes.draw do
  # Health check
  get "up" => "rails/health#show", as: :rails_health_check

  # Storefront - Tests SQL and View tracing
  resources :products, only: [:index]

  # Checkout - Tests trace propagation to background jobs
  resources :orders, only: [:create]
  post "/checkout", to: "orders#create"

  # Error testing - Tests error recording
  get "/crash", to: "pages#crash"

  # RUM Bridge - Tests browser-to-backend trace linking
  get "/shop", to: "pages#shop"

  # Root
  root "pages#shop"
end
