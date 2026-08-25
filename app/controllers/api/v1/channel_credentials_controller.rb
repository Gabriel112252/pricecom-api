module Api
  module V1
    class ChannelCredentialsController < ApplicationController
      before_action :validate_channel!, only: [ :connect, :sync, :update_role ]
      before_action :require_admin!, only: [ :connect, :update_role, :backfill_orders ]

      # GET /api/v1/integrations/channels
      # Keeps one top-level card per provider for frontend compatibility, but
      # exposes every concrete store connection in `connections`.
      def index
        credentials_by_channel = current_tenant.channel_credentials.order(:id).group_by(&:channel)
        logs_by_channel = recent_logs_by_channel

        render json: ChannelCredential::CHANNELS.map { |channel|
          credentials = credentials_by_channel[channel] || []
          primary = credentials.first
          channel_json(channel, primary, logs_by_channel[channel] || []).merge(
            connections: credentials.map { |credential| connection_json(credential, recent_logs_for(credential)) }
          )
        }
      end

      # POST /api/v1/integrations/:channel/connect
      # Optional selectors:
      #   channel_credential_id: edits one existing connection
      #   name: creates/edits a named store connection (e.g. Hidrabene/Anasol)
      # With neither selector, legacy behavior is preserved only while the
      # provider has zero or one connection; multiple stores must be explicit.
      def connect
        credential = resolve_credential(params[:channel], build: true)
        return render_resolution_error unless credential

        credential.credentials = credential_params
        credential.status = "pending"

        unless credential.save
          return render json: { errors: credential.errors.full_messages }, status: :unprocessable_entity
        end

        log_activity!(
          action: "channel_credential.updated",
          target: credential,
          metadata: {
            channel: credential.channel,
            channel_credential_id: credential.id,
            connection_name: credential.display_name
          }
        )

        if credential.channel == "lucrofrete"
          begin
            Integrations::LucrofreteClient.new(credential).authenticate!
            credential.update!(status: "active")
          rescue Integrations::AuthenticationError, Integrations::ApiError, Integrations::RateLimitError => e
            credential.update!(status: "error")
            return render json: { errors: [ e.message ] }, status: :unprocessable_entity
          end

          return render json: connection_json(credential, [])
        end

        # Channel remains provider-level for orders/pricing compatibility.
        Channel.ensure_for!(current_tenant, credential.channel)

        # OAuth channels only persist app credentials here; the exact
        # connection id is then carried through authorize_url/callback.
        if %w[tiktok shopee].include?(credential.channel)
          return render json: connection_json(credential, [])
        end

        begin
          adapter_class = Integrations::ProductSyncService::ADAPTERS.fetch(credential.channel)
          adapter_class.new(credential.credentials).authenticate
          credential.update!(status: "active")
        rescue Integrations::AuthenticationError, Integrations::ApiError, Integrations::RateLimitError => e
          credential.update!(status: "error")
          return render json: { errors: [ e.message ] }, status: :unprocessable_entity
        end

        render json: connection_json(credential, [])
      end

      # PATCH /api/v1/integrations/:channel/role
      def update_role
        credential = resolve_credential(params[:channel])
        return render_resolution_error("Canal ainda não conectado") unless credential

        credential.role = params[:role] if params[:role].present?
        credential.stock_source_channel = resolve_stock_source

        if credential.save
          render json: connection_json(credential, recent_logs_for(credential))
        else
          render json: { errors: credential.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/integrations/:channel/sync
      def sync
        credential = resolve_credential(params[:channel])
        return render_resolution_error("Canal ainda não conectado") unless credential

        if credential.status == "pending"
          return render json: { error: "Canal ainda não conectado" }, status: :unprocessable_entity
        end

        unless Integrations::ProductSyncService::ADAPTERS.key?(credential.channel)
          return render json: {
            error: "Sincronização de produtos não suportada para o canal #{credential.channel}"
          }, status: :unprocessable_entity
        end

        result = Integrations::ProductSyncService.call(credential)
        credential.reload

        render json: {
          success: result.success?,
          synced_count: result.synced_count,
          error_message: result.error_message,
          connection: connection_json(credential, recent_logs_for(credential))
        }
      end

      # POST /api/v1/integrations/yampi/backfill_orders
      # Yampi is expected to remain the shared checkout. If it ever has more
      # than one connection, the operation refuses to guess which one to use.
      def backfill_orders
        credential = ChannelCredential.resolve_for(tenant: current_tenant, channel: "yampi")

        unless credential
          count = current_tenant.channel_credentials.where(channel: "yampi").limit(2).count
          message = count > 1 ? "Existem várias conexões Yampi; selecione a conexão explicitamente" : "Yampi ainda não está conectada"
          return render json: { error: message }, status: :unprocessable_entity
        end

        if credential.status == "pending"
          return render json: { error: "Yampi ainda não está conectada" }, status: :unprocessable_entity
        end

        if yampi_order_polling_running?(credential)
          return render json: {
            success: true,
            enqueued: false,
            already_running: true,
            message: "Sincronização de pedidos da Yampi já está em execução",
            connection: connection_json(credential, recent_logs_for(credential))
          }, status: :accepted
        end

        job = Integrations::Yampi::OrdersPollingJob.perform_later(credential.id, trigger: "manual")

        render json: {
          success: true,
          enqueued: true,
          job_id: job.job_id,
          connection: connection_json(credential, recent_logs_for(credential))
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

      def resolve_credential(channel, build: false)
        @credential_resolution_error = nil
        scope = current_tenant.channel_credentials.where(channel: channel)

        if params[:channel_credential_id].present?
          credential = scope.find_by(id: params[:channel_credential_id])
          @credential_resolution_error = "Conexão não encontrada para #{channel}" unless credential
          return credential
        end

        connection_name = params[:name].to_s.strip.presence
        if connection_name
          return build ? scope.find_or_initialize_by(name: connection_name) : scope.find_by(name: connection_name).tap { |record|
            @credential_resolution_error = "Conexão '#{connection_name}' não encontrada para #{channel}" unless record
          }
        end

        records = scope.order(:id).limit(2).to_a
        return records.first if records.one?

        if records.empty?
          return current_tenant.channel_credentials.new(
            channel: channel,
            name: ChannelCredential.default_name_for(channel)
          ) if build

          @credential_resolution_error = "Canal ainda não conectado"
          return nil
        end

        @credential_resolution_error = "Existem várias conexões para #{channel}; informe channel_credential_id ou name"
        nil
      end

      def render_resolution_error(fallback = nil)
        render json: { error: @credential_resolution_error.presence || fallback || "Conexão não encontrada" },
          status: :unprocessable_entity
      end

      def resolve_stock_source
        credential_id = params[:stock_source_channel_credential_id]
        if credential_id.present?
          return current_tenant.channel_credentials.find_by(id: credential_id)
        end

        channel_param = params[:stock_source_channel]
        return nil if channel_param.blank?

        ChannelCredential.resolve_for(tenant: current_tenant, channel: channel_param)
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
          .where(
            "channel_credential_id = :id OR metadata->>'channel_credential_id' = :id_string",
            id: credential.id,
            id_string: credential.id.to_s
          )
          .order(created_at: :desc)
          .limit(5)
          .map { |l| log_json(l) }
      end

      def channel_json(channel, credential, logs)
        {
          id: credential&.id,
          channel: channel,
          name: credential&.display_name,
          status: credential&.status || "pending",
          required_fields: ChannelCredential::REQUIRED_FIELDS.fetch(channel),
          credentials_configured: credentials_configured?(channel, credential),
          last_synced_at: credential&.last_synced_at,
          orders_sync_cursor_at: credential&.orders_sync_cursor_at,
          polling_enabled: credential&.polling_enabled,
          orders_polling_running: yampi_order_polling_running?(credential),
          role: credential&.role,
          stock_source_channel: credential&.stock_source_channel&.channel,
          stock_source_channel_credential_id: credential&.stock_source_channel_id,
          stock_source_connection_name: credential&.stock_source_channel&.display_name,
          recent_logs: logs
        }
      end

      def connection_json(credential, logs)
        channel_json(credential.channel, credential, logs).merge(
          channel_credential_id: credential.id,
          connection_name: credential.display_name
        )
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
          id: log.id,
          status: log.status,
          error_message: log.error_message,
          action: log.action,
          synced_count: log.metadata["synced_count"],
          created_count: log.metadata["created_count"],
          updated_count: log.metadata["updated_count"],
          unchanged_count: log.metadata["unchanged_count"],
          ignored_count: log.metadata["ignored_count"],
          error_count: log.metadata["error_count"],
          trigger: log.metadata["trigger"],
          started_at: log.started_at,
          finished_at: log.finished_at
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
