module Api
  module V1
    # Camada fina de cache para os dois endpoints mais caros do Dashboard.
    #
    # O dado operacional continua vindo das mesmas queries/serviços; o cache
    # só evita recalcular exatamente o mesmo tenant/período/canais a cada
    # refresh ou navegação. TTL curto mantém o painel próximo de tempo real.
    class DashboardCachedController < DashboardController
      OVERVIEW_TTL = 60.seconds
      EXTENDED_TTL = 3.minutes

      def summary
        payload = Rails.cache.fetch(cache_key("overview"), expires_in: OVERVIEW_TTL) do
          Dashboard::BuildSummary.call_overview(tenant: current_tenant, params: params)
        end

        render json: payload
      end

      def summary_extended
        payload = Rails.cache.fetch(cache_key("extended"), expires_in: EXTENDED_TTL) do
          Dashboard::BuildSummary.call_extended(tenant: current_tenant, params: params)
        end

        render json: payload
      end

      private

      def cache_key(kind)
        channels = Array(params[:channel_ids]).map(&:to_s).reject(&:blank?).sort
        from = params[:from].to_s
        to = params[:to].to_s

        [
          "pricecom",
          "dashboard",
          "v1",
          kind,
          "tenant-#{current_tenant.id}",
          "from-#{from}",
          "to-#{to}",
          "channels-#{channels.join(',')}"
        ].join(":")
      end
    end
  end
end
