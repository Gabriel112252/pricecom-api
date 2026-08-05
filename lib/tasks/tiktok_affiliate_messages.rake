namespace :tiktok do
  namespace :affiliate_messages do
    desc "Corrige a direção (inbound/outbound) de AffiliateMessage sincronizadas antes do fix de " \
         "ChannelCredential#tiktok_seller_im_sender_id — sender_id no payload de mensagens é do " \
         "namespace de IM interno da TikTok, nunca bate contra AffiliateCreator#creator_open_id " \
         "(namespace de Affiliate/Collaboration), então toda mensagem sincronizada caía no fallback " \
         "antigo 'outbound', inclusive respostas reais de criadores (confirmado em produção, tenant " \
         "Hidrabene, 2026-08-06: duas respostas da fabibessa_ gravadas como outbound). " \
         "Só reprocessa dado já persistido (raw_payload salvo pelo sync) — não bate na API do TikTok " \
         "de novo. Exige que tiktok_seller_im_sender_id já esteja aprendido na credencial (acontece " \
         "sozinho na primeira sincronização normal pós-deploy que reconhecer uma mensagem nossa já " \
         "existente — ver Integrations::Tiktok::AffiliateConversationSyncService#learn_seller_sender_id); " \
         "tenants sem esse valor ainda são pulados com um aviso, não travam a task inteira. " \
         "Uso: bin/rails 'tiktok:affiliate_messages:fix_directions[tenant_slug]' (omita tenant_slug ou " \
         "use 'all' para rodar em todos os tenants TikTok)"
    task :fix_directions, [ :tenant_slug ] => :environment do |_t, args|
      tenant_slug = args[:tenant_slug]

      credentials = ChannelCredential.where(channel: "tiktok")
      if tenant_slug.present? && !tenant_slug.casecmp?("all")
        tenant = Tenant.find_by(slug: tenant_slug)
        abort "Tenant '#{tenant_slug}' não encontrado" unless tenant
        credentials = credentials.where(tenant_id: tenant.id)
      end
      abort "Nenhuma ChannelCredential tiktok encontrada" if credentials.none?

      total_fixed = 0
      credentials.find_each do |credential|
        seller_id = credential.tiktok_seller_im_sender_id
        if seller_id.blank?
          puts "tenant_id=#{credential.tenant_id}: tiktok_seller_im_sender_id ainda não aprendido — " \
               "pulando (abra o drawer de um criador, ou espere uma campanha rodar, para disparar o " \
               "aprendizado automático, depois rode esta task de novo)"
          next
        end

        # Só linhas que vieram do sync têm raw_payload (mensagens criadas por
        # AffiliateMessageSendService nunca têm — ver o guard de
        # #learn_seller_sender_id no service) — o -> 'message_body' ->>
        # 'sender_id' IS NOT NULL já exclui essas por construção.
        scope = AffiliateMessage
          .joins(:affiliate_creator)
          .where(affiliate_creators: { tenant_id: credential.tenant_id })
          .where(direction: "outbound")
          .where("affiliate_messages.raw_payload -> 'message_body' ->> 'sender_id' IS NOT NULL")
          .where.not("affiliate_messages.raw_payload -> 'message_body' ->> 'sender_id' = ?", seller_id.to_s)

        fixed = scope.update_all(direction: "inbound", updated_at: Time.current)
        total_fixed += fixed
        puts "tenant_id=#{credential.tenant_id} seller_id=#{seller_id} corrigidas=#{fixed}"
      end

      puts "Done. total_corrigidas=#{total_fixed}"
    end

    desc "Remove AffiliateMessage duplicadas criadas antes do fix que passou a capturar " \
         "external_message_id em AffiliateMessageSendService: mensagens enviadas por nós antes desse " \
         "fix ficaram com external_message_id nil e raw_payload vazio; a sincronização seguinte não " \
         "tinha como reconhecer esse id como já existente e inseriu uma SEGUNDA linha para a mesma " \
         "mensagem, essa sim com external_message_id e raw_payload corretos (exemplo real: " \
         "AffiliateMessage id=16 da fabibessa_ duplicando id=98). " \
         "Não bate na API — só compara linhas já persistidas: para cada linha SEM external_message_id, " \
         "procura outra do mesmo affiliate_creator_id, mesma direction, mesmo content, com sent_at a " \
         "até WINDOW_SECONDS (default 10) de distância e COM external_message_id — se achar, apaga a " \
         "linha sem external_message_id (a com external_message_id é sempre a mais confiável, veio " \
         "direto da API). Pede confirmação antes de apagar. " \
         "Uso: bin/rails 'tiktok:affiliate_messages:dedupe[tenant_slug]' WINDOW_SECONDS=10"
    task :dedupe, [ :tenant_slug ] => :environment do |_t, args|
      window_seconds = ENV["WINDOW_SECONDS"].to_i.positive? ? ENV["WINDOW_SECONDS"].to_i : 10
      tenant_slug = args[:tenant_slug]

      scope = AffiliateMessage.where(external_message_id: nil)
      if tenant_slug.present? && !tenant_slug.casecmp?("all")
        tenant = Tenant.find_by(slug: tenant_slug)
        abort "Tenant '#{tenant_slug}' não encontrado" unless tenant
        scope = scope.joins(:affiliate_creator).where(affiliate_creators: { tenant_id: tenant.id })
      end

      candidates = scope.select do |message|
        AffiliateMessage
          .where(affiliate_creator_id: message.affiliate_creator_id)
          .where(direction: message.direction)
          .where(content: message.content)
          .where.not(external_message_id: nil)
          .where(sent_at: (message.sent_at - window_seconds.seconds)..(message.sent_at + window_seconds.seconds))
          .exists?
      end

      puts "window_seconds=#{window_seconds}"
      puts "tenant_slug=#{tenant_slug.presence || 'all'}"
      puts "duplicatas_encontradas=#{candidates.size}"

      if candidates.empty?
        puts "Nada para apagar."
        next
      end

      candidates.each do |message|
        puts "  id=#{message.id} affiliate_creator_id=#{message.affiliate_creator_id} " \
             "sent_at=#{message.sent_at} content=#{message.content.to_s.truncate(60)}"
      end

      print "Confirma a exclusão dessas #{candidates.size} linha(s)? (digite 'sim' para continuar): "
      confirmation = $stdin.gets&.strip
      if confirmation != "sim"
        puts "Cancelado."
        next
      end

      deleted = 0
      candidates.each do |message|
        message.destroy!
        deleted += 1
      end

      puts "Done. deletadas=#{deleted}"
    end
  end
end
