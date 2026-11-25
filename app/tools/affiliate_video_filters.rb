# frozen_string_literal: true

# Filtros e ordens que ListarVideosAfiliadasTool e
# BaixarVideosAfiliadasEmLoteTool compartilham.
module AffiliateVideoFilters
  ORDERS = { "recentes" => :newest_first, "gmv" => :top_gmv_first, "views" => :most_viewed_first }.freeze
  INVALID_ORDER = "Ordem inválida. Use recentes, gmv ou views."
  INVALID_DATE = "Data inválida. Use o formato YYYY-MM-DD."

  private

  # Levanta Date::Error com uma data malformada (quem chama responde
  # INVALID_DATE).
  def filter_affiliate_videos(scope, criadora: nil, produto: nil, from: nil, to: nil)
    if criadora.present?
      term = "%#{ActiveRecord::Base.sanitize_sql_like(criadora.to_s.delete_prefix("@").downcase)}%"
      scope = scope.where("LOWER(affiliate_videos.username) LIKE :term OR LOWER(affiliate_videos.nickname) LIKE :term", term: term)
    end
    if produto.present?
      scope = scope.where("affiliate_videos.products::text ILIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(produto.to_s)}%")
    end
    scope = scope.where("affiliate_videos.posted_at >= ?", Date.parse(from).beginning_of_day) if from.present?
    scope = scope.where("affiliate_videos.posted_at <= ?", Date.parse(to).end_of_day) if to.present?
    scope
  end

  # O nome do scope de AffiliateVideo para a ordem pedida, ou nil se ela não
  # existe.
  def affiliate_video_order(ordem)
    ORDERS[ordem.to_s.strip.downcase.presence || "recentes"]
  end
end
