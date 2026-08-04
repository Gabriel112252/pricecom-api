module Api
  module V1
    class AffiliateCampaignsController < ApplicationController
      def index
        campaigns = current_tenant.affiliate_campaigns.order(created_at: :desc)
        render json: { rows: campaigns.map { |campaign| campaign_json(campaign) } }
      end

      def show
        campaign = current_tenant.affiliate_campaigns.find(params[:id])
        render json: campaign_json(campaign, with_recipients: true)
      end

      # POST /api/v1/affiliate_campaigns — cria a campanha e enfileira o
      # disparo em background; NUNCA despacha mensagens dentro do request
      # (potencialmente dezenas de chamadas sequenciais à TikTok).
      def create
        channel = current_tenant.channels.find_by(platform: "tiktok")
        return render json: { errors: [ "canal tiktok não encontrado" ] }, status: :unprocessable_entity unless channel

        campaign = current_tenant.affiliate_campaigns.new(
          channel: channel,
          name: params[:name],
          segment_filter: params[:segment_filter].presence || {},
          message_template: params[:message_template],
          created_by: current_user,
          status: "draft"
        )

        if campaign.save
          Integrations::Tiktok::AffiliateCampaignDispatchJob.perform_later(campaign.id)
          render json: campaign_json(campaign), status: :created
        else
          render json: { errors: campaign.errors.full_messages }, status: :unprocessable_entity
        end
      end

      private

      def campaign_json(campaign, with_recipients: false)
        json = {
          id: campaign.id,
          name: campaign.name,
          status: campaign.status,
          segment_filter: campaign.segment_filter,
          message_template: campaign.message_template,
          recipients_count: campaign.affiliate_campaign_recipients.count,
          sent_count: campaign.sent_count,
          failed_count: campaign.failed_count,
          created_at: campaign.created_at
        }.merge(unread_metrics(campaign))

        json[:recipients] = campaign.affiliate_campaign_recipients.includes(:affiliate_creator).map { |r| recipient_json(r) } if with_recipients
        json
      end

      def recipient_json(recipient)
        {
          id: recipient.id,
          affiliate_creator_id: recipient.affiliate_creator_id,
          nickname: recipient.affiliate_creator.nickname,
          status: recipient.status,
          sent_at: recipient.sent_at,
          error_message: recipient.error_message
        }
      end

      # "Ainda não visualizou" é calculado ao vivo (Get Latest Unread
      # Messages, cruzado por conversation_id) — sem persistir/job separado,
      # ver AffiliateCampaignDispatchService's class comment sobre a
      # limitação: unread_message_count é por conversa, não por mensagem.
      def unread_metrics(campaign)
        sent_recipients = campaign.affiliate_campaign_recipients.where(status: "sent").includes(:affiliate_creator)
        return { not_viewed_estimate: nil, unread_check_failed: false } if sent_recipients.empty?

        channel_credential = current_tenant.channel_credentials.find_by(channel: "tiktok")
        return { not_viewed_estimate: nil, unread_check_failed: true } unless channel_credential

        adapter = Integrations::TiktokAdapter.new(channel_credential.credentials)
        unread_conversation_ids = adapter.fetch_latest_unread_messages
          .select { |message| message["unread_message_count"].to_i.positive? }
          .map { |message| message["conversation_id"] }
          .to_set

        conversation_ids = sent_recipients.map { |recipient| recipient.affiliate_creator.conversation_id }.compact
        not_viewed = conversation_ids.count { |id| unread_conversation_ids.include?(id) }
        { not_viewed_estimate: not_viewed, unread_check_failed: false }
      rescue Integrations::AuthenticationError, Integrations::RateLimitError, Integrations::ApiError
        { not_viewed_estimate: nil, unread_check_failed: true }
      end
    end
  end
end
