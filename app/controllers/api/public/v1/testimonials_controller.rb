module Api
  module Public
    module V1
      # Public, unauthenticated, CORS-open endpoint for storefront widgets
      # (Shopify JS client-side today). Two uses from the same action:
      #   - no shopify_product_id: every published testimonial of the tenant
      #     (home widget).
      #   - shopify_product_id present: only testimonials linked to that
      #     product — legitimately an empty array when the product has none
      #     yet (not an error; the frontend hides the block in that case).
      #
      # Tenant is resolved via testimonials_public_token (see
      # Tenant#regenerate_testimonials_public_token!), NOT slug — slug is a
      # plain readable identifier, not a secret, and would let anyone
      # enumerate other tenants' published testimonials by guessing slugs.
      #
      # Response fields are a strict allowlist (testimonial_json below) —
      # never the full admin serialization (Api::V1::TestimonialsController),
      # which includes id/tenant/product internals not meant for a public,
      # cross-origin caller.
      class TestimonialsController < ApplicationController
        skip_before_action :authenticate_request!
        before_action :set_tenant_from_token!

        CACHE_EXPIRES_IN = 10.minutes

        def index
          render json: { testimonials: cached_testimonials }
        end

        private

        def set_tenant_from_token!
          token = params[:tenant].presence
          @current_tenant = token && Tenant.find_by(testimonials_public_token: token)

          render json: { error: "Tenant inválido" }, status: :not_found unless @current_tenant
        end

        # Keyed on tenant + product filter so the home widget and every
        # per-product widget cache independently; media_url is baked into
        # the cached payload using public_host (never the request's own
        # Host header), so it's stable regardless of which caller/origin
        # populated the cache.
        def cached_testimonials
          Rails.cache.fetch(cache_key, expires_in: CACHE_EXPIRES_IN) do
            testimonials_scope.map { |testimonial| testimonial_json(testimonial) }
          end
        end

        def cache_key
          [ "public_testimonials", current_tenant.id, shopify_product_id || "all" ].join("/")
        end

        def testimonials_scope
          scope = current_tenant.testimonials.by_status("published").order(published_at: :desc)
          return scope if shopify_product_id.blank?

          # external_product_id is the Shopify PARENT product id, shared by
          # every variant listing of that product — matches on it, not
          # external_id (the per-variant id), and dedupes since more than
          # one listing can point at the same local product.
          product_ids = ChannelProductListing
            .where(tenant: current_tenant, channel: "shopify", external_product_id: shopify_product_id)
            .distinct
            .pluck(:product_id)

          scope.where(product_id: product_ids)
        end

        def shopify_product_id
          params[:shopify_product_id].presence
        end

        def testimonial_json(testimonial)
          {
            customer_name: testimonial.customer_name,
            rating:        testimonial.rating,
            quote_text:    testimonial.quote_text,
            media_url:     media_url(testimonial),
            thumbnail_url: thumbnail_url(testimonial),
            source_type:   testimonial.source_type
          }
        end

        # Absolute URL (not the admin panel's rails_blob_path) — this is
        # consumed cross-origin by a Shopify storefront, a relative path
        # would resolve against the STORE's own domain, not ours. Points at
        # the ORIGINAL file (video or image) — only the widget's modal
        # should load this; the carousel card must use thumbnail_url below.
        def media_url(testimonial)
          return nil unless testimonial.media.attached?

          Rails.application.routes.url_helpers.rails_blob_url(testimonial.media, host: public_host)
        end

        # Always an image, never a video — for image media this is just
        # media_url (nothing extra to generate); for video media it's the
        # frame Testimonials::GenerateThumbnailJob extracted into #thumbnail.
        # nil (not a fallback to the raw video URL) if that job hasn't run
        # yet — an <img> pointed at a video file wouldn't render, which is
        # exactly the bug this field exists to avoid.
        def thumbnail_url(testimonial)
          return media_url(testimonial) unless video_media?(testimonial)
          return nil unless testimonial.thumbnail.attached?

          Rails.application.routes.url_helpers.rails_blob_url(testimonial.thumbnail, host: public_host)
        end

        def video_media?(testimonial)
          testimonial.media.attached? && testimonial.media.content_type.start_with?("video/")
        end

        # In production this is APP_HOST (see config/environments/production.rb),
        # set once and never derived from the request — request.base_url would
        # report "localhost" for internal calls (health checks, curl from
        # inside the container), breaking media_url for the end customer.
        # Dev/test don't set routes.default_url_options[:host], so they fall
        # back to request.base_url as before.
        def public_host
          Rails.application.routes.default_url_options[:host] || request.base_url
        end
      end
    end
  end
end
