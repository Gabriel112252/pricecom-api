source "https://rubygems.org"

# API
gem "rails", "~> 7.2"
gem "pg", "~> 1.1"
gem "puma", "~> 8.0"
gem "rack-cors"

# Auth
gem "bcrypt", "~> 3.1.7"
gem "jwt"

# Background jobs
gem "sidekiq", "~> 7.3"
gem "sidekiq-cron"

# Background jobs
gem "sidekiq", "~> 7.3"
gem "sidekiq-cron"
gem "connection_pool", "~> 2.5"

# Utilities
gem "kaminari"
gem "active_model_serializers"
gem "roo"

# Channel integrations (Yampi/Shopify/TikTok product sync)
gem "faraday"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

group :development, :test do
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"
  gem "dotenv-rails"

  gem "brakeman", require: false
  gem "rubocop-rails-omakase", require: false
end

group :test do
  gem "rspec-rails"
  gem "webmock"
end
