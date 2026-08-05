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
      # DashboardController#tiktok_orders. Criadores com mensagem não lida
      # sempre sobem para o topo, automaticamente — não é uma opção de sort
      # configurável, é sempre aplicado por cima do sort escolhido (ver
      # #order_clause). Por isso unread_conversation_ids precisa ser
      # calculado ANTES de paginar: uma mensagem não lida na página 3 não
      # tem como "furar a fila" se a gente só souber quem tem unread depois
      # de já ter cortado a página.
      def creators
        channel = current_tenant.channels.find_by(platform: "tiktok")
        return render json: { rows: [], meta: pagination_meta_empty } unless channel

        scope = Affiliates::FilterCreators.call(tenant: current_tenant, channel: channel, params: params)
        sort = CREATOR_SORTS.fetch(params[:sort].to_s, CREATOR_SORTS["synced_at"])
        direction = params[:direction].to_s.downcase == "asc" ? "ASC" : "DESC"
        per = [ [ params.fetch(:per_page, PER_PAGE_DEFAULT).to_i, 1 ].max, PER_PAGE_MAX ].min
        unread_ids = unread_conversation_ids
        paged = scope.reorder(order_clause(sort, direction, unread_ids), id: :asc).page(params[:page]).per(per)

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
      # Api::V1::AffiliateCampaignsController#unread_metrics: UMA chamada a
      # Get Latest Unread Messages, cruzada em memória por conversation_id
      # — nunca uma chamada por criador. Chamado ANTES de paginar (ver
      # #creators/#order_clause), então sempre reflete o tenant inteiro, não
      # só a página atual — é o que permite furar a fila de qualquer
      # página, não só priorizar dentro da página já cortada. Sem
      # credencial ou com falha na API, devolve um Set vazio (ninguém
      # marcado como unread, sort cai de volta ao normal) em vez de quebrar
      # a listagem.
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

      # unread_conversation_ids isn't a DB column — it's resolved in Ruby
      # from a TikTok API call — so it can't be an ORDER BY term on its
      # own. A CASE WHEN over the already-resolved conversation_id list
      # buys a real SQL sort: unread creators (0) before everyone else (1),
      # then params[:sort]/params[:direction] as the tie-breaker within
      # each group. Empty unread_conversation_ids (no credential, API
      # error, or genuinely nothing unread) skips the CASE WHEN entirely —
      # same query shape as before this feature existed.
      def order_clause(sort, direction, unread_conversation_ids)
        return Arel.sql("#{sort} #{direction}") if unread_conversation_ids.blank?

        unread_case = ActiveRecord::Base.sanitize_sql_array(
          [ "CASE WHEN affiliate_creators.conversation_id IN (?) THEN 0 ELSE 1 END", unread_conversation_ids.to_a ]
        )
        Arel.sql("#{unread_case}, #{sort} #{direction}")
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
