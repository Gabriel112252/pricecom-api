require "rails_helper"

RSpec.describe "Testimonials", type: :request do
  let(:tenant)   { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:admin)    { tenant.users.create!(name: "Admin", email: "admin@#{SecureRandom.hex(4)}.com", password: "password123", role: "admin") }
  let(:operador) { tenant.users.create!(name: "Operador", email: "op@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador") }
  let(:product)  { tenant.products.create!(sku: "SKU-1", name: "Produto 1", cost_price: 10) }

  def auth_headers(user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user_id: user.id)}" }
  end

  let(:valid_params) { { customer_name: "Ana", product_id: product.id, rating: 5, quote_text: "Adorei o produto!" } }

  describe "GET /api/v1/testimonials" do
    it "lists the tenant's testimonials" do
      testimonial = tenant.testimonials.create!(valid_params.except(:product_id).merge(source_type: "manual", status: "draft"))
      testimonial.product_ids = [ product.id ]

      get "/api/v1/testimonials", headers: auth_headers(operador)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["testimonials"].size).to eq(1)
      expect(body["testimonials"].first["customer_name"]).to eq("Ana")
      expect(body["testimonials"].first["products"]).to eq([ { "id" => product.id, "name" => product.name, "sku" => product.sku } ])
      expect(body["meta"]["total_count"]).to eq(1)
    end

    it "does not leak another tenant's testimonials" do
      other_tenant = Tenant.create!(name: "Outra Loja", slug: "outra-loja-#{SecureRandom.hex(4)}")
      other_tenant.testimonials.create!(customer_name: "Bia", source_type: "manual", status: "draft")

      get "/api/v1/testimonials", headers: auth_headers(operador)

      expect(JSON.parse(response.body)["testimonials"]).to eq([])
    end

    it "filters by status" do
      draft = tenant.testimonials.create!(valid_params.merge(source_type: "manual", status: "draft"))
      tenant.testimonials.create!(valid_params.merge(customer_name: "Carla", source_type: "manual", status: "draft")).approve!

      get "/api/v1/testimonials", params: { status: "draft" }, headers: auth_headers(operador)

      body = JSON.parse(response.body)
      expect(body["testimonials"].map { |t| t["id"] }).to eq([ draft.id ])
    end

    it "filters by source_type" do
      tenant.testimonials.create!(valid_params.merge(source_type: "manual", status: "draft"))

      get "/api/v1/testimonials", params: { source_type: "tiktok" }, headers: auth_headers(operador)

      expect(JSON.parse(response.body)["testimonials"]).to eq([])
    end

    it "does not require admin to read" do
      get "/api/v1/testimonials", headers: auth_headers(operador)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /api/v1/testimonials" do
    it "requires admin" do
      post "/api/v1/testimonials", params: valid_params, headers: auth_headers(operador)
      expect(response).to have_http_status(:forbidden)
    end

    it "creates a manual, draft testimonial for an admin, always ignoring any client-sent status" do
      post "/api/v1/testimonials", params: valid_params.merge(status: "published"), headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      testimonial = tenant.testimonials.last
      expect(testimonial.source_type).to eq("manual")
      expect(testimonial.status).to eq("draft")
      expect(testimonial.customer_name).to eq("Ana")
    end

    it "falls back to the manual path for a source_type it doesn't special-case yet (e.g. shopee)" do
      post "/api/v1/testimonials", params: valid_params.merge(source_type: "shopee"), headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      expect(tenant.testimonials.last.source_type).to eq("manual")
    end

    it "accepts a media attachment" do
      file = fixture_file_upload("testimonial_photo.jpg", "image/jpeg")

      post "/api/v1/testimonials", params: valid_params.merge(media: file), headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      testimonial = tenant.testimonials.last
      expect(testimonial.media).to be_attached
      expect(JSON.parse(response.body)["media_url"]).to be_present
    end

    it "enqueues GenerateQuoteTextJob when media is attached" do
      file = fixture_file_upload("testimonial_photo.jpg", "image/jpeg")
      enqueued_ids = []
      allow(Testimonials::GenerateQuoteTextJob).to receive(:perform_later) { |id| enqueued_ids << id }
      allow(Testimonials::GenerateThumbnailJob).to receive(:perform_later)

      post "/api/v1/testimonials", params: valid_params.merge(media: file), headers: auth_headers(admin)

      expect(enqueued_ids).to eq([ tenant.testimonials.last.id ])
    end

    it "does not enqueue GenerateQuoteTextJob when there is no media" do
      expect(Testimonials::GenerateQuoteTextJob).not_to receive(:perform_later)

      post "/api/v1/testimonials", params: valid_params, headers: auth_headers(admin)
    end

    it "enqueues GenerateThumbnailJob when media is attached" do
      file = fixture_file_upload("testimonial_photo.jpg", "image/jpeg")
      enqueued_ids = []
      allow(Testimonials::GenerateQuoteTextJob).to receive(:perform_later)
      allow(Testimonials::GenerateThumbnailJob).to receive(:perform_later) { |id| enqueued_ids << id }

      post "/api/v1/testimonials", params: valid_params.merge(media: file), headers: auth_headers(admin)

      expect(enqueued_ids).to eq([ tenant.testimonials.last.id ])
    end

    it "does not enqueue GenerateThumbnailJob when there is no media" do
      expect(Testimonials::GenerateThumbnailJob).not_to receive(:perform_later)

      post "/api/v1/testimonials", params: valid_params, headers: auth_headers(admin)
    end

    it "links to a single product via the legacy singular product_id param (backward compat)" do
      post "/api/v1/testimonials", params: valid_params, headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      expect(tenant.testimonials.last.product_ids).to eq([ product.id ])
    end

    it "links to multiple products via product_ids" do
      other_product = tenant.products.create!(sku: "SKU-2", name: "Produto 2", cost_price: 5)

      post "/api/v1/testimonials",
        params: valid_params.except(:product_id).merge(product_ids: [ product.id, other_product.id ]),
        headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      expect(tenant.testimonials.last.product_ids.sort).to eq([ product.id, other_product.id ].sort)
      expect(JSON.parse(response.body)["products"].map { |p| p["id"] }.sort).to eq([ product.id, other_product.id ].sort)
    end

    it "creates with no product linked when neither product_id nor product_ids is sent" do
      post "/api/v1/testimonials", params: valid_params.except(:product_id), headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      expect(tenant.testimonials.last.products).to eq([])
    end

    it "rejects a product_id belonging to a different tenant, without creating the testimonial" do
      other_tenant = Tenant.create!(name: "Outra Loja", slug: "outra-loja-#{SecureRandom.hex(4)}")
      other_product = other_tenant.products.create!(sku: "SKU-X", name: "Produto X", cost_price: 10)

      expect {
        post "/api/v1/testimonials",
          params: valid_params.except(:product_id).merge(product_ids: [ other_product.id ]),
          headers: auth_headers(admin)
      }.not_to change(Testimonial, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["errors"]).to be_present
    end

    it "rejects invalid params" do
      post "/api/v1/testimonials", params: valid_params.merge(rating: 9), headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["errors"]).to be_present
    end
  end

  describe "POST /api/v1/testimonials (source_type: tiktok)" do
    let(:tiktok_url) { "https://www.tiktok.com/@usuario/video/1234567890" }
    let(:tiktok_params) { { customer_name: "Ana", source_type: "tiktok", external_url: tiktok_url } }

    def stub_oembed_success
      stub_request(:get, "https://www.tiktok.com/oembed").with(query: { url: tiktok_url }).to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          title: "Vídeo incrível",
          author_name: "usuario",
          thumbnail_url: "https://p16-sign.tiktokcdn.com/thumb.jpeg",
          html: "<blockquote class=\"tiktok-embed\">...</blockquote>"
        }.to_json
      )
    end

    def stub_oembed_failure
      stub_request(:get, "https://www.tiktok.com/oembed").with(query: { url: tiktok_url }).to_return(status: 404, body: "Not Found")
    end

    it "requires admin" do
      stub_oembed_success
      post "/api/v1/testimonials", params: tiktok_params, headers: auth_headers(operador)
      expect(response).to have_http_status(:forbidden)
    end

    it "creates a draft testimonial with the oEmbed metadata cached in tiktok_metadata" do
      stub_oembed_success

      post "/api/v1/testimonials", params: tiktok_params, headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      testimonial = tenant.testimonials.last
      expect(testimonial.source_type).to eq("tiktok")
      expect(testimonial.status).to eq("draft")
      expect(testimonial.external_url).to eq(tiktok_url)
      expect(testimonial.tiktok_metadata).to eq(
        "title" => "Vídeo incrível",
        "author_name" => "usuario",
        "thumbnail_url" => "https://p16-sign.tiktokcdn.com/thumb.jpeg",
        "html" => "<blockquote class=\"tiktok-embed\">...</blockquote>"
      )

      body = JSON.parse(response.body)
      expect(body["tiktok_metadata"]["author_name"]).to eq("usuario")
    end

    it "enqueues DownloadTiktokVideoJob (not GenerateQuoteTextJob directly — no media yet)" do
      stub_oembed_success
      enqueued_ids = []
      allow(Testimonials::DownloadTiktokVideoJob).to receive(:perform_later) { |id| enqueued_ids << id }
      expect(Testimonials::GenerateQuoteTextJob).not_to receive(:perform_later)

      post "/api/v1/testimonials", params: tiktok_params, headers: auth_headers(admin)

      expect(enqueued_ids).to eq([ tenant.testimonials.last.id ])
    end

    it "does not create a testimonial when the oEmbed fetch fails, and returns a clear error" do
      stub_oembed_failure

      expect {
        post "/api/v1/testimonials", params: tiktok_params, headers: auth_headers(admin)
      }.not_to change(Testimonial, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["errors"]).to include("link inválido ou vídeo indisponível")
    end

    it "still scopes the created record to current_tenant" do
      stub_oembed_success

      post "/api/v1/testimonials", params: tiktok_params, headers: auth_headers(admin)

      expect(tenant.testimonials.last.tenant_id).to eq(tenant.id)
    end
  end

  describe "POST /api/v1/testimonials/tiktok_preview" do
    let(:tiktok_url) { "https://www.tiktok.com/@usuario/video/1234567890" }

    it "does not require admin (same access as index)" do
      stub_request(:get, "https://www.tiktok.com/oembed").with(query: { url: tiktok_url }).to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { title: "t", author_name: "a", thumbnail_url: "u", html: "h" }.to_json
      )

      post "/api/v1/testimonials/tiktok_preview", params: { url: tiktok_url }, headers: auth_headers(operador)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body).to eq("title" => "t", "author_name" => "a", "thumbnail_url" => "u", "html" => "h")
    end

    it "does not create any testimonial" do
      stub_request(:get, "https://www.tiktok.com/oembed").with(query: { url: tiktok_url }).to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { title: "t", author_name: "a", thumbnail_url: "u", html: "h" }.to_json
      )

      expect {
        post "/api/v1/testimonials/tiktok_preview", params: { url: tiktok_url }, headers: auth_headers(operador)
      }.not_to change(Testimonial, :count)
    end

    it "returns a clear error for an invalid/unavailable link" do
      stub_request(:get, "https://www.tiktok.com/oembed").with(query: { url: tiktok_url }).to_return(status: 404, body: "Not Found")

      post "/api/v1/testimonials/tiktok_preview", params: { url: tiktok_url }, headers: auth_headers(operador)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to eq("link inválido ou vídeo indisponível")
    end
  end

  describe "PUT /api/v1/testimonials/:id" do
    it "requires admin" do
      testimonial = tenant.testimonials.create!(valid_params.merge(source_type: "manual", status: "draft"))
      put "/api/v1/testimonials/#{testimonial.id}", params: { quote_text: "Editado" }, headers: auth_headers(operador)
      expect(response).to have_http_status(:forbidden)
    end

    it "updates editable fields" do
      testimonial = tenant.testimonials.create!(valid_params.merge(source_type: "manual", status: "draft"))

      put "/api/v1/testimonials/#{testimonial.id}", params: { quote_text: "Editado", rating: 4 }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      testimonial.reload
      expect(testimonial.quote_text).to eq("Editado")
      expect(testimonial.rating).to eq(4)
    end

    it "does not leak cross-tenant records" do
      other_tenant = Tenant.create!(name: "Outra Loja", slug: "outra-loja-#{SecureRandom.hex(4)}")
      other_testimonial = other_tenant.testimonials.create!(customer_name: "Bia", source_type: "manual", status: "draft")

      put "/api/v1/testimonials/#{other_testimonial.id}", params: { quote_text: "x" }, headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
    end

    it "leaves already-linked products untouched when neither product_id nor product_ids is sent" do
      testimonial = tenant.testimonials.create!(customer_name: "Ana", source_type: "manual", status: "draft")
      testimonial.product_ids = [ product.id ]

      put "/api/v1/testimonials/#{testimonial.id}", params: { quote_text: "Editado" }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(testimonial.reload.product_ids).to eq([ product.id ])
    end

    it "syncs to a new set of products via product_ids (adds and removes in the same call)" do
      other_product = tenant.products.create!(sku: "SKU-2", name: "Produto 2", cost_price: 5)
      testimonial = tenant.testimonials.create!(customer_name: "Ana", source_type: "manual", status: "draft")
      testimonial.product_ids = [ product.id ]

      put "/api/v1/testimonials/#{testimonial.id}", params: { product_ids: [ other_product.id ] }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(testimonial.reload.product_ids).to eq([ other_product.id ])
    end

    it "clears all linked products when product_ids is sent empty" do
      testimonial = tenant.testimonials.create!(customer_name: "Ana", source_type: "manual", status: "draft")
      testimonial.product_ids = [ product.id ]

      put "/api/v1/testimonials/#{testimonial.id}", params: { product_ids: [ "" ] }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(testimonial.reload.products).to eq([])
    end

    it "rejects syncing to a product from a different tenant, leaving existing links untouched" do
      other_tenant = Tenant.create!(name: "Outra Loja", slug: "outra-loja-#{SecureRandom.hex(4)}")
      other_product = other_tenant.products.create!(sku: "SKU-X", name: "Produto X", cost_price: 10)
      testimonial = tenant.testimonials.create!(customer_name: "Ana", source_type: "manual", status: "draft")
      testimonial.product_ids = [ product.id ]

      put "/api/v1/testimonials/#{testimonial.id}", params: { product_ids: [ other_product.id ] }, headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["errors"]).to be_present
      expect(testimonial.reload.product_ids).to eq([ product.id ])
    end
  end

  describe "status transitions" do
    it "approves a draft testimonial" do
      testimonial = tenant.testimonials.create!(valid_params.merge(source_type: "manual", status: "draft"))

      post "/api/v1/testimonials/#{testimonial.id}/approve", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(testimonial.reload.status).to eq("approved")
      expect(testimonial.approved_at).to be_present
    end

    it "requires admin to approve" do
      testimonial = tenant.testimonials.create!(valid_params.merge(source_type: "manual", status: "draft"))

      post "/api/v1/testimonials/#{testimonial.id}/approve", headers: auth_headers(operador)

      expect(response).to have_http_status(:forbidden)
    end

    it "rejects publishing a draft directly, with a clear error" do
      testimonial = tenant.testimonials.create!(valid_params.merge(source_type: "manual", status: "draft"))

      post "/api/v1/testimonials/#{testimonial.id}/publish", headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/draft.*published/)
      expect(testimonial.reload.status).to eq("draft")
    end

    it "publishes an approved testimonial" do
      testimonial = tenant.testimonials.create!(valid_params.merge(source_type: "manual", status: "draft"))
      testimonial.approve!

      post "/api/v1/testimonials/#{testimonial.id}/publish", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(testimonial.reload.status).to eq("published")
      expect(testimonial.published_at).to be_present
    end

    it "approves and publishes a testimonial with no quote_text — rating/media-only is a valid testimonial" do
      testimonial = tenant.testimonials.create!(valid_params.merge(source_type: "manual", status: "draft", quote_text: nil))

      post "/api/v1/testimonials/#{testimonial.id}/approve", headers: auth_headers(admin)
      expect(response).to have_http_status(:ok)

      post "/api/v1/testimonials/#{testimonial.id}/publish", headers: auth_headers(admin)
      expect(response).to have_http_status(:ok)
      expect(testimonial.reload.status).to eq("published")
      expect(testimonial.quote_text).to be_nil
    end

    it "rejects a draft testimonial" do
      testimonial = tenant.testimonials.create!(valid_params.merge(source_type: "manual", status: "draft"))

      post "/api/v1/testimonials/#{testimonial.id}/reject", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(testimonial.reload.status).to eq("rejected")
    end

    it "does not allow rejecting an already published testimonial" do
      testimonial = tenant.testimonials.create!(valid_params.merge(source_type: "manual", status: "draft"))
      testimonial.approve!
      testimonial.publish!

      post "/api/v1/testimonials/#{testimonial.id}/reject", headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(testimonial.reload.status).to eq("published")
    end
  end

  describe "DELETE /api/v1/testimonials/:id" do
    it "requires admin" do
      testimonial = tenant.testimonials.create!(valid_params.merge(source_type: "manual", status: "draft"))
      delete "/api/v1/testimonials/#{testimonial.id}", headers: auth_headers(operador)
      expect(response).to have_http_status(:forbidden)
    end

    it "removes the testimonial" do
      testimonial = tenant.testimonials.create!(valid_params.merge(source_type: "manual", status: "draft"))

      delete "/api/v1/testimonials/#{testimonial.id}", headers: auth_headers(admin)

      expect(response).to have_http_status(:no_content)
      expect(Testimonial.exists?(testimonial.id)).to eq(false)
    end
  end
end
