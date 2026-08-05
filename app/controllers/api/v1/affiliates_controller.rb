module Api
  module V1
    class AffiliatesController < ApplicationController
      PER_PAGE_DEFAULT = 25
      PER_PAGE_MAX = 100
      CREATOR_SORTS = {
        "showcase_product_count" => "affiliate_creators.showcase_product_count",
        "content_product_count" => "affiliate_creators.content_product_count",
        "synced_at" => "affiliate_creators.synced_at"
      }.freeze

      def overview
        channel = current_tenant.channels.find_by(platform: "tiktok")
        return render json: { supported: false } unless channel

        creators = channel.affiliate_creators.where(tenant: current_tenant)
        render json: {
          supported: true,
          total_creators: creators.count,
          active_creators: creators.where(collaboration_status: "NORMAL").count,
          showcase_product_count_total: creators.sum(:showcase_product_count),
          content_product_count_total: creators.sum(:content_product_count),
          daily_snapshots: daily_snapshots(channel),
          top_creators_by_content: top_creators_by_content(creators)
        }
      end

      # GET /api/v1/affiliates/creators — tabela "Meus Afiliados", mesmo
      # padrão de scope inline + whitelist de sort do
      # DashboardController#tiktok_orders.
      def creators
        channel = current_tenant.channels.find_by(platform: "tiktok")
        return render json: { rows: [], meta: pagination_meta_empty } unless channel

        scope = Affiliates::FilterCreators.call(tenant: current_tenant, channel: channel, params: params)
        sort = CREATOR_SORTS.fetch(params[:sort].to_s, CREATOR_SORTS["synced_at"])
        direction = params[:direction].to_s.downcase == "asc" ? "ASC" : "DESC"
        per = [ [ params.fetch(:per_page, PER_PAGE_DEFAULT).to_i, 1 ].max, PER_PAGE_MAX ].min
        paged = scope.reorder(Arel.sql("#{sort} #{direction}"), id: :asc).page(params[:page]).per(per)
        unread_ids = paged.any? ? unread_conversation_ids : Set.new

        render json: { rows: paged.map { |creator| creator_json(creator, unread_conversation_ids: unread_ids) }, meta: pagination_meta(paged) }
      end

      def creator
        creator = current_tenant.affiliate_creators.find(params[:id])
        render json: creator_json(creator)
      end

      # GET /api/v1/affiliates/creators/:id/messages — sincroniza o
      # histórico real da conversa (TikTok Get Message in the Conversation,
      # paginado) antes de devolver as mensagens persistidas. Síncrono
      # dentro do request, como #send_message — o drawer chama isso ao
      # abrir/trocar de criador, latência aceitável para uma conversa só.
      # Se a sync falhar (rate limit, credencial expirada), ainda assim
      # devolve o que já está persistido de syncs anteriores, marcando
      # sync_failed para o frontend avisar sem quebrar o resto do drawer.
      def messages
        creator = current_tenant.affiliate_creators.find(params[:id])
        sync_failed = false
        begin
          Integrations::Tiktok::AffiliateConversationSyncService.call(affiliate_creator: creator)
        rescue Integrations::AuthenticationError, Integrations::RateLimitError, Integrations::ApiError
          sync_failed = true
        end

        rows = creator.affiliate_messages.order(:sent_at).map { |m| message_json(m) }
        render json: { rows: rows, sync_failed: sync_failed }
      end

      # POST /api/v1/affiliates/creators/:id/messages — envio individual,
      # síncrono (uma mensagem só, latência aceitável dentro do request).
      def send_message
        creator = current_tenant.affiliate_creators.find(params[:id])
        message = Integrations::Tiktok::AffiliateMessageSendService.call(
          affiliate_creator: creator, content: params[:content].to_s
        )
        render json: { id: message.id, sent_at: message.sent_at, conversation_id: creator.conversation_id }
      rescue Integrations::AuthenticationError, Integrations::RateLimitError, Integrations::ApiError => e
        render json: { errors: [ e.message ] }, status: :unprocessable_entity
      end

      private

      def daily_snapshots(channel)
        AffiliateDailySnapshot.where(tenant: current_tenant, channel: channel)
          .order(:snapshot_date).last(90)
          .map { |s| { date: s.snapshot_date.iso8601, active_creators: s.active_creators_count, total_creators: s.total_creators_count } }
      end

      def top_creators_by_content(creators)
        creators.order(content_product_count: :desc).limit(10).map do |c|
          { label: c.username.presence || c.nickname, name: c.nickname, value: c.content_product_count }
        end
      end

      def creator_json(creator, unread_conversation_ids: Set.new)
        {
          id: creator.id,
          creator_open_id: creator.creator_open_id,
          username: creator.username,
          nickname: creator.nickname,
          avatar_url: creator.avatar_url,
          collaboration_status: creator.collaboration_status,
          showcase_product_count: creator.showcase_product_count,
          content_product_count: creator.content_product_count,
          target_collaboration_id: creator.target_collaboration_id,
          conversation_id: creator.conversation_id,
          synced_at: creator.synced_at,
          has_unread: creator.conversation_id.present? && unread_conversation_ids.include?(creator.conversation_id)
        }
      end

      # "Mensagem não lida" por criador na listagem — mesma fonte de dado e
      # mesma degradação graciosa de
      # Api::V1::AffiliateCampaignsController#unread_metrics (uma chamada só
      # a Get Latest Unread Messages para a página inteira, cruzada em
      # memória por conversation_id — nunca uma chamada por criador). Sem
      # credencial ou com falha na API, devolve um Set vazio (ninguém
      # marcado como unread) em vez de quebrar a listagem.
      def unread_conversation_ids
        channel_credential = current_tenant.channel_credentials.find_by(channel: "tiktok")
        return Set.new unless channel_credential

        adapter = Integrations::TiktokAdapter.new(channel_credential.credentials)
        adapter.fetch_latest_unread_messages
          .select { |message| message["unread_message_count"].to_i.positive? }
          .map { |message| message["conversation_id"] }
          .to_set
      rescue Integrations::AuthenticationError, Integrations::RateLimitError, Integrations::ApiError
        Set.new
      end

      def message_json(message)
        {
          id: message.id,
          direction: message.direction,
          content: message.content,
          sent_at: message.sent_at
        }
      end

      def pagination_meta(paged)
        {
          current_page: paged.current_page,
          total_pages: paged.total_pages,
          total_count: paged.total_count,
          per_page: paged.limit_value
        }
      end

      def pagination_meta_empty
        { current_page: 1, total_pages: 0, total_count: 0, per_page: PER_PAGE_DEFAULT }
      end
    end
  end
end
