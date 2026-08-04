module Affiliates
  # Shared filter used both by the "Meus Afiliados" listing endpoint and by
  # campaign creation, so "how many recipients" always matches between the
  # campaign preview and the table.
  class FilterCreators
    def self.call(tenant:, channel:, params: {})
      new(tenant: tenant, channel: channel, params: params).call
    end

    def initialize(tenant:, channel:, params:)
      @tenant = tenant
      @channel = channel
      # Accepts both an ActionController::Parameters (creators listing
      # endpoint) and a plain Hash (AffiliateCampaign#segment_filter, read
      # back from jsonb) — to_h alone raises on an unpermitted
      # ActionController::Parameters.
      @params = (params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h).with_indifferent_access
    end

    def call
      scope = channel.affiliate_creators.where(tenant: tenant)
      scope = scope.where(collaboration_status: params[:collaboration_status]) if params[:collaboration_status].present?
      scope = scope.where(target_collaboration_id: params[:target_collaboration_id]) if params[:target_collaboration_id].present?
      scope
    end

    private

    attr_reader :tenant, :channel, :params
  end
end
