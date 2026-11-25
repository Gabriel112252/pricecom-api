# frozen_string_literal: true

class SincronizarVideosAfiliadasTool < ApplicationTool
  description "Busca no TikTok Shop os vídeos das criadoras com colaboração direcionada: atualiza as criadoras das " \
    "colaborações e depois os vídeos dos últimos dias, e baixa os arquivos novos em segundo plano. Roda em segundo " \
    "plano; use listar_videos_afiliadas em alguns minutos para ver o resultado."

  arguments do
    optional(:dias).filled(:integer).description("Quantos dias para trás buscar (padrão 60, máx 365)")
  end

  # Sem confirmar: true — só lê do TikTok e grava no próprio Pricecom, mesmo
  # job que um cron rodaria; admin-only pelo mesmo motivo de
  # DispararSyncCanalTool (dispara chamadas de API e downloads).
  def call(dias: nil)
    admin_error = require_admin!
    return admin_error if admin_error

    tenant = current_tenant
    return "Usuário sem tenant associado." unless tenant

    credentials = tenant.channel_credentials.active.where(channel: "tiktok").order(:id).to_a
    return "TikTok Shop ainda não está conectado (ou a conexão está com erro). Conecte em Integrações." if credentials.empty?

    days_back = (dias.presence || Integrations::Tiktok::AffiliateVideoSyncService::DEFAULT_DAYS_BACK).to_i
      .clamp(1, Integrations::Tiktok::AffiliateVideoSyncService::MAX_DAYS_BACK)

    credentials.each do |credential|
      Integrations::Tiktok::AffiliateVideoSyncJob.perform_later(credential.id, days_back: days_back)
      log_activity!(
        action: "channel_sync.triggered",
        target: credential,
        metadata: { channel: "tiktok", kind: "affiliate_videos", days_back: days_back, source: "mcp" }
      )
    end

    {
      confirmacao: "Sincronização dos vídeos de afiliadas disparada.",
      dias: days_back,
      conexoes_tiktok: credentials.map(&:display_name),
      proximo_passo: "Use listar_videos_afiliadas em alguns minutos."
    }
  end
end
