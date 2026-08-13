source "https://rubygems.org"

# API
gem "rails", "~> 7.2"
gem "pg", "~> 1.1"
gem "puma", "~> 8.0"
gem "rack-cors"
gem "rack-attack"

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

# ZIP extraction (Testimonials::BulkImportService) — já vinha transitivo via
# roo, mas nosso código chama Zip::File direto, então fica explícito aqui em
# vez de depender de uma dependência transitiva de outra gem.
gem "rubyzip", require: "zip"

# Channel integrations (Yampi/Shopify/TikTok product sync)
gem "faraday"

# Anthropic API (Testimonials::AnthropicVisionClient — geração de quote_text a
# partir de foto/frame de vídeo)
gem "anthropic"

# MCP server (item 5 do roadmap) — expõe tools de leitura/escrita pra
# clientes MCP (Claude Desktop, Claude.ai). Mesma gem e versão já em
# produção no ScrumFlow (~/projetos/scrumflow/back) — ver
# config/initializers/fast_mcp.rb pro monkey-patch de auth que replica o
# de lá (bugs confirmados ainda presentes na 1.6.0, a mais recente
# publicada até este levantamento).
gem "fast-mcp", "~> 1.6"

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
