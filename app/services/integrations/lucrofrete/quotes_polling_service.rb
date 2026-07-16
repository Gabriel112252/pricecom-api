module Integrations
  module Lucrofrete
    # Pulls freight-quote logs from LucroFrete's GET /api/logs.
    #
    # Legacy note: /api/logs is kept only as a raw quote-analysis source.
    # It must not write Order#real_freight_cost anymore; the authoritative
    # real freight source is /api/reports/orders via OrdersSyncService.
    #
    # That endpoint takes NO date filter (confirmed in production —
    # start_date/end_date are silently ignored, unlike /api/reports/*), so
    # incremental sync works by walking pages sequentially and STOPPING at
    # the first external_id already present in the database. This covers
    # both the first run (full backfill — nothing exists, walks every
    # page) and later runs (stops on page 1 almost immediately).
    #
    # ASSUMPTION (to be confirmed in production): pagination appears to be
    # ordered most-recent-first. If a NEW external_id shows up after we've
    # already seen existing ones, that assumption is broken — the record is
    # still upserted (no data loss), but a warning is logged and counted in
    # metadata (new_after_existing_count) so it can be investigated.
    class QuotesPollingService
      MAX_PAGES = 1_000 # hard safety cap (100k logs) against runaway pagination

      Result = Struct.new(:outcome, :error_message, :metadata, keyword_init: true) do
        def success? = outcome == :success
        def error?   = outcome == :error
      end

      def self.call(channel_credential, trigger: "scheduled")
        new(channel_credential, trigger: trigger).call
      end

      def initialize(channel_credential, trigger: "scheduled")
        @channel_credential = channel_credential
        @tenant = channel_credential.tenant
        @trigger = trigger
        @integration = tenant.integrations.active.find_by(provider: "lucrofrete")
        @client = Integrations::LucrofreteClient.new(channel_credential)
        @started_at = Time.current
        @pages_fetched = 0
        @logs_received = 0
        @created_count = 0
        @updated_count = 0
        @existing_count = 0
        @new_after_existing_count = 0
        @error_count = 0
        @item_errors = []
      end

      def call
        @log = start_log
        channel = Channel.ensure_for!(tenant, "yampi") # source é sempre "yampi" (confirmado)

        fetch_and_process_pages(channel)

        if @error_count.positive?
          finish_log(status: "error", error_message: @item_errors.first&.fetch(:message, nil))
          return result(:error, @item_errors.first&.fetch(:message, nil))
        end

        channel_credential.update!(last_synced_at: Time.current, status: "active")
        finish_log(status: "success")
        result(:success, nil)
      rescue Integrations::AuthenticationError => e
        channel_credential.update!(status: "error")
        finish_log(status: "error", error_message: e.message)
        result(:error, e.message)
      rescue Integrations::ApiError, Integrations::RateLimitError => e
        finish_log(status: "error", error_message: e.message)
        result(:error, e.message)
      rescue => e
        finish_log(status: "error", error_message: e.message)
        result(:error, e.message)
      end

      private

      attr_reader :channel_credential, :tenant, :trigger, :integration, :client, :started_at, :log

      def fetch_and_process_pages(channel)
        page = 1
        seen_existing = false

        loop do
          body = client.fetch_logs_page(page: page)
          @pages_fetched += 1

          logs = body.is_a?(Hash) && body["logs"].is_a?(Array) ? body["logs"] : []
          break if logs.empty?

          @logs_received += logs.size
          seen_existing = process_logs(logs, channel, seen_existing: seen_existing)

          # Para na página em que encontrou registros já conhecidos — o
          # resto da página já foi processado acima, então nada se perde.
          break if seen_existing

          total = body["total"].to_i
          break if total.positive? && page * Integrations::LucrofreteClient::LOGS_LIMIT >= total
          break if logs.size < Integrations::LucrofreteClient::LOGS_LIMIT
          break if page >= MAX_PAGES

          page += 1
        end
      end

      # → true se algum external_id já existente foi encontrado (nesta ou
      # em página anterior).
      def process_logs(logs, channel, seen_existing:)
        logs.each do |raw_log|
          external_id = raw_log["id"].to_s
          next if external_id.blank?

          if tenant.freight_quotes.exists?(external_id: external_id)
            @existing_count += 1
            seen_existing = true
            next
          end

          if seen_existing
            # Suposição de ordenação (recente → antigo) violada: um log
            # NOVO apareceu depois de já termos visto conhecidos. Upserta
            # mesmo assim (sem perda), mas avisa para investigação.
            @new_after_existing_count += 1
            Rails.logger.warn(
              "[Integrations::Lucrofrete::QuotesPollingService] external_id novo (#{external_id}) " \
              "encontrado APÓS registros já existentes — a suposição de ordenação " \
              "mais-recente-primeiro do /api/logs pode estar errada; rode um backfill completo para garantir."
            )
          end

          upsert_quote(raw_log, channel)
        rescue => e
          @error_count += 1
          @item_errors << { external_id: raw_log["id"], message: e.message } if @item_errors.size < 10
        end

        seen_existing
      end

      def upsert_quote(raw_log, channel)
        rp = raw_log["request_payload"].is_a?(Hash) ? raw_log["request_payload"] : {}

        quote = tenant.freight_quotes.create!(
          channel:            channel,
          external_id:        raw_log["id"].to_s,
          cart_external_id:   rp.dig("cart", "id")&.to_s,
          origin_cep:         extract_cep(rp, %w[origin_cep cep_origem zipcode_from], %w[origin seller]),
          destination_cep:    extract_cep(rp, %w[destination_cep cep_destino zipcode_to zipcode], %w[destination customer cart]),
          destination_state:  extract_destination_state(rp),
          total_weight_grams: extract_weight_grams(rp),
          quoted_at:          parse_time(raw_log["created_at"]),
          quotes:             normalize_quotes(raw_log["response_payload"])
        )
        @created_count += 1
        quote
      end

      # CEP de origem/destino: shape do request_payload NÃO confirmado em
      # produção (só cart.id foi confirmado) — candidatos defensivos em
      # chaves planas e aninhadas. nil quando nada casa; validar com um log
      # real e podar.
      def extract_cep(rp, flat_keys, nested_parents)
        flat = flat_keys.map { |k| rp[k] }.find(&:present?)
        return normalize_cep(flat) if flat.present?

        nested = nested_parents.map { |parent|
          node = rp[parent]
          next unless node.is_a?(Hash)
          node["cep"] || node["zipcode"] || node["postal_code"]
        }.find(&:present?)

        normalize_cep(nested)
      end

      def normalize_cep(value)
        digits = value.to_s.gsub(/\D/, "")
        digits.presence
      end

      def extract_destination_state(rp)
        %w[destination customer cart address].map { |parent|
          node = rp[parent]
          next unless node.is_a?(Hash)
          node["state"] || node["uf"]
        }.find(&:present?) || rp["destination_state"].presence
      end

      # Peso: unidade NÃO confirmada — assumido gramas quando a chave já
      # diz "grams"; para "total_weight"/"weight" o valor é gravado como
      # está (validar unidade com um log real antes de usar em cálculos).
      def extract_weight_grams(rp)
        value = rp["total_weight_grams"] || rp["total_weight"] || rp["weight"] || rp.dig("cart", "total_weight")
        return nil if value.blank?

        value.to_f.round
      end

      def normalize_quotes(response_payload)
        return [] unless response_payload.is_a?(Array)

        response_payload.filter_map do |option|
          next unless option.is_a?(Hash)

          {
            "slot_name"       => option["slot_name"],
            "carrier_name"    => option["carrier_name"],
            "service"         => option["service"],
            "name"            => option["name"],
            "price"           => option["price"].to_f,
            "cost_price"      => option["cost_price"].to_f,
            "free_shipment"   => option["free_shipment"] == true,
            "source_provider" => option["source_provider"],
            "days"            => option["days"]
          }
        end
      end

      def parse_time(value)
        return nil if value.blank?

        Time.zone.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def start_log
        IntegrationSyncLog.create!(
          tenant: tenant,
          integration: integration,
          direction: "inbound",
          action: "lucrofrete_quotes_polling",
          status: "pending",
          started_at: started_at,
          metadata: { trigger: trigger, channel: "lucrofrete", channel_credential_id: channel_credential.id }
        )
      end

      def finish_log(status:, error_message: nil)
        return unless log

        finished_at = Time.current
        log.update!(
          status: status,
          finished_at: finished_at,
          duration_ms: ((finished_at - started_at) * 1000).round,
          error_message: error_message,
          metadata: log.metadata.merge(count_metadata)
        )
      end

      def count_metadata
        {
          pages_fetched: @pages_fetched,
          logs_received: @logs_received,
          created_count: @created_count,
          existing_count: @existing_count,
          new_after_existing_count: @new_after_existing_count,
          real_freight_cost_application: "disabled; reports/orders is authoritative",
          error_count: @error_count,
          errors: @item_errors
        }
      end

      def result(outcome, error_message)
        Result.new(outcome: outcome, error_message: error_message, metadata: count_metadata)
      end
    end
  end
end
