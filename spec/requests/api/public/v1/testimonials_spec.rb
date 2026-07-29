require "rails_helper"

RSpec.describe "Public Testimonials API", type: :request do
  let(:tenant) do
    t = Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}")
    t.regenerate_testimonials_public_token!
    t
  end
  let(:token)   { tenant.testimonials_public_token }
  let(:product) { tenant.products.create!(sku: "SKU-1", name: "Produto 1", cost_price: 10) }

  def make_published_testimonial(product: nil, customer_name: "Ana", rating: 5, quote_text: "Ótimo!")
    testimonial = tenant.testimonials.create!(
      customer_name: customer_name, source_type: "manual", status: "draft",
      product: product, rating: rating, quote_text: quote_text
    )
    testimonial.approve!
    testimonial.publish!
    testimonial
  end

  def link_shopify_product(product, external_product_id:, external_id: SecureRandom.hex(6))
    tenant.channel_product_listings.create!(
      product: product, channel: "shopify", external_id: external_id,
      external_product_id: external_product_id, selling_status: "selling"
    )
  end

  describe "GET /api/public/v1/testimonials" do
    it "requires no authentication and returns published testimonials for the tenant (home widget)" do
      make_published_testimonial

      get "/api/public/v1/testimonials", params: { tenant: token }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["testimonials"].size).to eq(1)
      expect(body["testimonials"].first["customer_name"]).to eq("Ana")
    end

    it "returns 404 for an invalid/missing token, without leaking whether the tenant exists" do
      get "/api/public/v1/testimonials", params: { tenant: "not-a-real-token" }
      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 when tenant param is absent entirely" do
      get "/api/public/v1/testimonials"
      expect(response).to have_http_status(:not_found)
    end

    it "excludes draft and approved (not yet published) testimonials" do
      tenant.testimonials.create!(customer_name: "Draft", source_type: "manual", status: "draft")
      tenant.testimonials.create!(customer_name: "Approved", source_type: "manual", status: "draft", quote_text: "Texto").approve!

      get "/api/public/v1/testimonials", params: { tenant: token }

      expect(JSON.parse(response.body)["testimonials"]).to eq([])
    end

    it "never leaks another tenant's testimonials" do
      other_tenant = Tenant.create!(name: "Outra Loja", slug: "outra-#{SecureRandom.hex(4)}")
      other = other_tenant.testimonials.create!(customer_name: "Outra", source_type: "manual", status: "draft", quote_text: "Texto")
      other.approve!
      other.publish!

      get "/api/public/v1/testimonials", params: { tenant: token }

      expect(JSON.parse(response.body)["testimonials"]).to eq([])
    end

    it "only returns the allowlisted fields, never id/tenant_id/product_id or other internal data" do
      make_published_testimonial

      get "/api/public/v1/testimonials", params: { tenant: token }

      row = JSON.parse(response.body)["testimonials"].first
      expect(row.keys.sort).to eq(%w[customer_name media_url quote_text rating source_type].sort)
    end

    it "includes an absolute media_url when media is attached" do
      testimonial = make_published_testimonial
      testimonial.media.attach(io: StringIO.new("fake"), filename: "foto.jpg", content_type: "image/jpeg")

      get "/api/public/v1/testimonials", params: { tenant: token }

      media_url = JSON.parse(response.body)["testimonials"].first["media_url"]
      expect(media_url).to match(%r{\Ahttp://})
    end

    it "returns media_url nil when there is no media attached" do
      make_published_testimonial

      get "/api/public/v1/testimonials", params: { tenant: token }

      expect(JSON.parse(response.body)["testimonials"].first["media_url"]).to be_nil
    end

    it "returns quote_text null, without breaking, for a rating/media-only testimonial" do
      make_published_testimonial(quote_text: nil)

      get "/api/public/v1/testimonials", params: { tenant: token }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["testimonials"].first["quote_text"]).to be_nil
    end

    it "uses the configured public host, never the request's own Host header (e.g. an internal call hitting the app as localhost)" do
      testimonial = make_published_testimonial
      testimonial.media.attach(io: StringIO.new("fake"), filename: "foto.jpg", content_type: "image/jpeg")

      original_host = Rails.application.routes.default_url_options[:host]
      Rails.application.routes.default_url_options[:host] = "https://pricecom-pricecom-api.dzxtro.easypanel.host"

      begin
        get "/api/public/v1/testimonials", params: { tenant: token }, headers: { "Host" => "localhost" }
      ensure
        Rails.application.routes.default_url_options[:host] = original_host
      end

      media_url = JSON.parse(response.body)["testimonials"].first["media_url"]
      expect(media_url).to start_with("https://pricecom-pricecom-api.dzxtro.easypanel.host")
    end

    describe "shopify_product_id filter" do
      it "returns only testimonials linked to that product" do
        other_product = tenant.products.create!(sku: "SKU-2", name: "Produto 2", cost_price: 5)
        link_shopify_product(product, external_product_id: "632910392")
        link_shopify_product(other_product, external_product_id: "999999999")
        make_published_testimonial(product: product, customer_name: "Do produto")
        make_published_testimonial(product: other_product, customer_name: "De outro produto")
        make_published_testimonial(customer_name: "Sem produto (geral)")

        get "/api/public/v1/testimonials", params: { tenant: token, shopify_product_id: "632910392" }

        names = JSON.parse(response.body)["testimonials"].map { |t| t["customer_name"] }
        expect(names).to eq([ "Do produto" ])
      end

      it "returns an empty array (not an error) when the product has no testimonial yet" do
        link_shopify_product(product, external_product_id: "632910392")
        make_published_testimonial(customer_name: "Geral, sem produto")

        get "/api/public/v1/testimonials", params: { tenant: token, shopify_product_id: "632910392" }

        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)["testimonials"]).to eq([])
      end

      it "returns an empty array (not an error) for a shopify_product_id with no matching listing at all" do
        make_published_testimonial

        get "/api/public/v1/testimonials", params: { tenant: token, shopify_product_id: "no-such-product" }

        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)["testimonials"]).to eq([])
      end

      it "matches on the shared parent product id, not the per-variant id" do
        link_shopify_product(product, external_id: "808950810", external_product_id: "632910392")
        make_published_testimonial(product: product)

        get "/api/public/v1/testimonials", params: { tenant: token, shopify_product_id: "808950810" }

        expect(JSON.parse(response.body)["testimonials"]).to eq([])
      end
    end

    describe "CORS" do
      it "allows a cross-origin request from a storefront domain" do
        get "/api/public/v1/testimonials", params: { tenant: token }, headers: { "Origin" => "https://minha-loja.myshopify.com" }

        expect(response.headers["Access-Control-Allow-Origin"]).to eq("*")
      end

      it "responds to a CORS preflight (OPTIONS) request without hitting the controller" do
        options "/api/public/v1/testimonials", headers: {
          "Origin" => "https://minha-loja.myshopify.com",
          "Access-Control-Request-Method" => "GET"
        }

        expect(response.headers["Access-Control-Allow-Origin"]).to eq("*")
      end
    end

    describe "rate limiting" do
      it "throttles a single IP past the configured per-minute limit" do
        limit = 60

        limit.times do
          get "/api/public/v1/testimonials", params: { tenant: token }
          expect(response).to have_http_status(:ok)
        end

        get "/api/public/v1/testimonials", params: { tenant: token }

        expect(response).to have_http_status(:too_many_requests)
        expect(JSON.parse(response.body)).to include("error")
      end
    end

    describe "caching" do
      around do |example|
        original_cache = Rails.cache
        Rails.cache = ActiveSupport::Cache::MemoryStore.new
        example.run
        Rails.cache = original_cache
      end

      it "serves a cached result on the second call, not seeing a testimonial published in between" do
        make_published_testimonial(customer_name: "Primeira")

        get "/api/public/v1/testimonials", params: { tenant: token }
        first_names = JSON.parse(response.body)["testimonials"].map { |t| t["customer_name"] }

        make_published_testimonial(customer_name: "Segunda")

        get "/api/public/v1/testimonials", params: { tenant: token }
        second_names = JSON.parse(response.body)["testimonials"].map { |t| t["customer_name"] }

        expect(first_names).to eq([ "Primeira" ])
        expect(second_names).to eq([ "Primeira" ])
      end

      it "caches the general and per-product results independently" do
        link_shopify_product(product, external_product_id: "632910392")
        make_published_testimonial(product: product, customer_name: "Do produto")

        get "/api/public/v1/testimonials", params: { tenant: token }
        general_names = JSON.parse(response.body)["testimonials"].map { |t| t["customer_name"] }

        get "/api/public/v1/testimonials", params: { tenant: token, shopify_product_id: "632910392" }
        by_product_names = JSON.parse(response.body)["testimonials"].map { |t| t["customer_name"] }

        expect(general_names).to eq([ "Do produto" ])
        expect(by_product_names).to eq([ "Do produto" ])
      end
    end
  end
end
