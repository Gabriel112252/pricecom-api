module Affiliates
  # Shared filter used both by the "Meus Afiliados" listing endpoint and by
  # campaign creation, so "how many recipients" always matches between the
  # campaign preview and the table.
  class FilterCreators
    # "NORMAL" is the only collaboration_status value confirmed against a
    # real production payload (see AffiliateSyncService/creator sync
    # fixture) — every segment below that reasons about "active" vs
    # "inactive" collaboration keys off this exact string, not a guess.
    ACTIVE_COLLABORATION_STATUS = "NORMAL".freeze

    # Funnel segments for campaign targeting (checkboxes in
    # AffiliateCampaignFormModal.vue). Multiple selected segments are
    # combined with OR (union of audiences) — see #apply_segments.
    #
    # "never_invited" (creator visible but with no target_collaboration at
    # all) and "replied"/"never_replied" (based on inbound messages) are
    # deliberately NOT implemented here — see the class comment block below
    # for why.
    #
    # never_invited: every AffiliateCreator row today is CREATED BY
    # AffiliateSyncService FROM a target_collaboration's creators[] — there
    # is no code path that persists a creator without one, because the
    # "Descobrir" marketplace-search tab (which would surface creators with
    # no collaboration yet) is out of scope (see the original Afiliados
    # investigation report). Nothing to filter on until that tab exists.
    #
    # replied / never_replied: confirmed by grepping this codebase —
    # AffiliateMessage.create! is only ever called from
    # AffiliateMessageSendService, always with direction: "outbound". No
    # inbound message has ever been persisted, and no job/webhook exists to
    # change that. Of the two conversation-history endpoints, "Get
    # Conversation List" (fetch_conversations) has no confirmed response
    # schema (only path/method were ever confirmed, unlike Create
    # Conversation / Get Latest Unread Messages), and "Get Message in the
    # Conversation" (the actual per-message thread) was deliberately left
    # unimplemented — its path was never confirmed, per the original
    # Afiliados plan. The one endpoint with a confirmed schema,
    # fetch_latest_unread_messages, only reports "this conversation
    # currently has an unread message" — ephemeral (clears once anyone
    # reads it, including via TikTok's own app outside Pricecom, not
    # necessarily Pricecom marking it read) and not equivalent to "this
    # creator has ever replied." Building "replied"/"never_replied" on that
    # signal would silently misrepresent what's actually known — so it's
    # not implemented instead of faked. Needs either a confirmed thread
    # endpoint or an explicit product decision to accept the unread-count
    # proxy with its caveats before this segment can exist.
    SEGMENTS = %w[accepted_no_content showcase_no_content inactive_collaboration].freeze

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
      scope = apply_segments(scope) if segments.present?
      scope = apply_search(scope) if params[:q].present?
      scope
    end

    private

    attr_reader :tenant, :channel, :params

    # Free-text search (nickname/username), "Meus Afiliados" only for now —
    # AffiliateCampaign#segment_filter is read back from a persisted jsonb
    # column, so `q` simply won't be present there unless campaign creation
    # decides to expose search too (not this task's scope).
    def apply_search(scope)
      term = "%#{params[:q].to_s.strip}%"
      scope.where("affiliate_creators.nickname ILIKE :term OR affiliate_creators.username ILIKE :term", term: term)
    end

    def segments
      Array(params[:segments]).map(&:to_s) & SEGMENTS
    end

    def apply_segments(scope)
      fragments = segments.map { |segment| segment_sql(segment) }
      scope.where(fragments.join(" OR "))
    end

    def segment_sql(segment)
      case segment
      # "Aceitou mas nunca postou" — colaboração ativa, zero conteúdo
      # publicado até agora.
      when "accepted_no_content"
        ActiveRecord::Base.sanitize_sql_array(
          [ "(collaboration_status = ? AND content_product_count = 0)", ACTIVE_COLLABORATION_STATUS ]
        )
      # "Produto na vitrine, zero conteúdo" — mais específico que o item
      # acima (independe do status da colaboração): tem produto exposto mas
      # nunca postou nada sobre ele.
      when "showcase_no_content"
        "(showcase_product_count > 0 AND content_product_count = 0)"
      # "Colaboração inativa" — qualquer status diferente do único valor
      # confirmado como ativo (NULL entra aqui também: nunca teve status
      # sincronizado, não é "ativo").
      when "inactive_collaboration"
        ActiveRecord::Base.sanitize_sql_array(
          [ "(collaboration_status IS NULL OR collaboration_status != ?)", ACTIVE_COLLABORATION_STATUS ]
        )
      end
    end
  end
end
