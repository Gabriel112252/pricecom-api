module Api
  module V1
    class ChannelCredentialsController < ApplicationController
      before_action :validate_channel!, only: [ :connect, :sync, :update_role ]
      before_action :require_admin!, only: [ :connect, :update_role, :backfill_orders ]

      # GET /api/v1/integrations/channels
      def index
        credentials = current_tenant.channel_credentials.index_by(&:channel)
        logs_by_channel = recent_logs_by_channel

        render json: ChannelCredential::CHANNELS.map { |channel|
          channel_json(channel, credentials[channel], logs_by_channel[channel] || [])
        }
      end

      # POST /api/v1/integrations/:channel/connect
      def connect
        credential = current_tenant.channel_credentials.find_or_initialize_by(channel: params[:channel])
        credential.credentials = credential_params
        credential.status = "pending"

        unless credential.save
          return render json: { errors: credential.errors.full_messages }, status: :unprocessable_entity
        end

        # A ChannelCredential alone doesn't give Order#channel_id anything to
        # point at — Channel is the older, separate table that's been driving
        # orders/pricing/commission since Etapa 1. Without this, order
        # ingestion (webhook or backfill) fails with "Canal não encontrado"
        # even though the channel looks fully connected and syncing products
        # fine. See Channel.ensure_for! and the one-off
        # channels:backfill_missing rake task for tenants connected before
        # this fix existed.
        Channel.ensure_for!(current_tenant, credential.channel)

        if credential.channel == "tiktok"
          return render json: channel_json(credential.channel, credential, [])
        end

        # Verify right away rather than making the user wait for the next
        # scheduled sync to find out the credentials don't work.
        begin
          adapter_class = Integrations::ProductSyncService::ADAPTERS.fetch(credential.channel)
          adapter_class.new(credential.credentials).authenticate
          credential.update!(status: "active")
        rescue Integrations::AuthenticationError, Integrations::ApiError, Integrations::RateLimitError => e
          credential.update!(status: "error")
          return render json: { errors: [ e.message ] }, status: :unprocessable_entity
        end

        render json: channel_json(credential.channel, credential, [])
      end

      # PATCH /api/v1/integrations/:channel/role
      # Configures whether this channel owns real stock (fonte_estoque /
      # ambos) or only places orders against another channel's inventory
      # (consumidor_pedido, e.g. Yampi checkout backed by Shopify).
      def update_role
        credential = current_tenant.channel_credentials.find_by(channel: params[:channel])
        unless credential
          return render json: { error: "Canal ainda não conectado" }, status: :unprocessable_entity
        end

        credential.role = params[:role] if params[:role].present?
        credential.stock_source_channel = resolve_stock_source(params[:stock_source_channel])

        if credential.save
          render json: channel_json(credential.channel, credential, recent_logs_for(credential))
        else
          render json: { errors: credential.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/integrations/:channel/sync
      def sync
        credential = current_tenant.channel_credentials.find_by(channel: params[:channel])

        if credential.nil? || credential.status == "pending"
          return render json: { error: "Canal ainda não conectado" }, status: :unprocessable_entity
        end

        result = Integrations::ProductSyncService.call(credential)
        credential.reload

        render json: {
          success: result.success?,
          synced_count: result.synced_count,
          error_message: result.error_message,
          channel: channel_json(credential.channel, credential, recent_logs_for(credential))
        }
      end

      # POST /api/v1/integrations/yampi/backfill_orders
      # Enqueues the same Yampi order polling job used by the scheduler.
      # The first job execution performs the 30-day created_at backfill when
      # orders_sync_cursor_at is blank; later executions use an incremental
      # created_at window. The HTTP request never performs API pagination.
      def backfill_orders
        credential = current_tenant.channel_credentials.find_by(channel: "yampi")

        if credential.nil? || credential.status == "pending"
          return render json: { error: "Yampi ainda não está conectada" }, status: :unprocessable_entity
        end

        if yampi_order_polling_running?(credential)
          return render json: {
            success: true,
            enqueued: false,
            already_running: true,
            message: "Sincronização de pedidos da Yampi já está em execução",
            channel: channel_json(credential.channel, credential, recent_logs_for(credential))
          }, status: :accepted
        end

        job = Integrations::Yampi::OrdersPollingJob.perform_later(credential.id, trigger: "manual")

        render json: {
          success: true,
          enqueued: true,
          job_id: job.job_id,
          channel: channel_json(credential.channel, credential, recent_logs_for(credential))
        }, status: :accepted
      end

      private

      def validate_channel!
        return if ChannelCredential::CHANNELS.include?(params[:channel])

        render json: { error: "Canal inválido" }, status: :not_found
      end

      def credential_params
        params.require(:credentials).permit!.to_h
      end

      def resolve_stock_source(channel_param)
        return nil if channel_param.blank?

        current_tenant.channel_credentials.find_by(channel: channel_param)
      end

      def recent_logs_by_channel
        IntegrationSyncLog
          .where(tenant: current_tenant, action: [ "product_sync", "yampi_order_polling" ])
          .order(created_at: :desc)
          .limit(100)
          .group_by { |log| log.metadata["channel"] }
          .transform_values { |logs| logs.first(5).map { |l| log_json(l) } }
      end

      def recent_logs_for(credential)
        IntegrationSyncLog
          .where(tenant: current_tenant, action: [ "product_sync", "yampi_order_polling" ])
          .where("metadata->>'channel_credential_id' = ?", credential.id.to_s)
          .order(created_at: :desc)
          .limit(5)
          .map { |l| log_json(l) }
      end

      def channel_json(channel, credential, logs)
        {
          id:                   credential&.id,
          channel:              channel,
          status:               credential&.status || "pending",
          required_fields:      ChannelCredential::REQUIRED_FIELDS.fetch(channel),
          credentials_configured: credentials_configured?(channel, credential),
          last_synced_at:       credential&.last_synced_at,
          orders_sync_cursor_at: credential&.orders_sync_cursor_at,
          polling_enabled:       credential&.polling_enabled,
          orders_polling_running: yampi_order_polling_running?(credential),
          role:                 credential&.role,
          stock_source_channel: credential&.stock_source_channel&.channel,
          recent_logs:          logs
        }
      end

      def credentials_configured?(channel, credential)
        return false unless credential

        credentials = credential.credentials.to_h
        ChannelCredential::REQUIRED_FIELDS.fetch(channel).all? do |field|
          credentials[field].present? || credentials[field.to_sym].present?
        end
      end

      def log_json(log)
        {
          id:            log.id,
          status:        log.status,
          error_message: log.error_message,
          action:        log.action,
          synced_count:  log.metadata["synced_count"],
          created_count: log.metadata["created_count"],
          updated_count: log.metadata["updated_count"],
          unchanged_count: log.metadata["unchanged_count"],
          ignored_count: log.metadata["ignored_count"],
          error_count:   log.metadata["error_count"],
          trigger:       log.metadata["trigger"],
          started_at:    log.started_at,
          finished_at:   log.finished_at
        }
      end

      def yampi_order_polling_running?(credential)
        return false unless credential&.channel == "yampi"

        Integrations::Yampi::PollingLock.new(credential).locked?
      rescue => e
        Rails.logger.warn("[ChannelCredentialsController] yampi polling lock check failed for channel_credential_id=#{credential&.id}: #{e.message}")
        false
      end
    end
  end
end
