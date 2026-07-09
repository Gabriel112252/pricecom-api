module Orders
  class ImportService
    COLUMN_MAP = {
      "Dt criação"     => :ordered_at,
      "Pedido"         => :order_number,
      "Status ped."    => :status,
      "Canal"          => :channel_platform,
      "Cliente"        => :customer_name,
      "Tags"           => :customer_tag,
      "UF"             => :state,
      "R$ prod"        => :gross_value,
      "R$ frete"       => :freight,
      "R$ pedido"      => :gross_value,
      "R$ custo"       => :cost_price,
      "R$ desconto"    => :discount,
      "Tipo pagamento" => :payment_method,
      "Peso (KG)"      => :weight_kg,
      "Qtde itens"     => :items_qty,
      "Integração"     => :integration_name,
    }.freeze

    PLATFORM_MAP = {
      "tiktok"        => "tiktok",
      "tik tok"       => "tiktok",
      "shopify"       => "shopify",
      "yampi"         => "yampi",
      "mercado livre" => "mercadolivre",
      "mercadolivre"  => "mercadolivre",
    }.freeze

    def initialize(tenant, file_path, import_record)
      @tenant = tenant
      @file_path = file_path
      @import = import_record
    end

    def call
      @import.update!(status: "processing")

      spreadsheet = Roo::Spreadsheet.open(@file_path)
      sheet = spreadsheet.sheet(0)

      header_row = nil
      (1..10).each do |i|
        row = sheet.row(i).map(&:to_s)
        if row.include?("Pedido") && row.include?("Canal")
          header_row = i
          break
        end
      end

      raise "Header não encontrado na planilha" unless header_row

      headers = sheet.row(header_row).map(&:to_s)
      total = sheet.last_row - header_row
      @import.update!(total_rows: total)

      processed = 0
      errors = []

      (header_row + 1..sheet.last_row).each do |row_num|
        row_data = sheet.row(row_num)
        next if row_data.compact.empty?

        row = headers.zip(row_data).to_h
        begin
          import_row(row)
          processed += 1
        rescue => e
          errors << { row: row_num, error: e.message }
        end

        @import.update!(processed_rows: processed) if processed % 50 == 0
      end

      @import.update!(
        status: errors.empty? ? "done" : "failed",
        processed_rows: processed,
        error_rows: errors.size,
        errors_log: errors,
        finished_at: Time.current
      )
    rescue => e
      @import.update!(status: "failed", errors_log: [{ error: e.message }])
      raise
    end

    private

    def import_row(row)
      integration = row["Integração"].to_s.downcase
      platform = PLATFORM_MAP.find { |k, _| integration.include?(k) }&.last || "shopify"
      channel = find_or_create_channel(platform, row["Integração"])

      ordered_at  = parse_date(row["Dt criação"])
      gross_value = parse_decimal(row["R$ pedido"])
      cost_price  = parse_decimal(row["R$ custo"]).abs
      freight     = parse_decimal(row["R$ frete"])
      discount    = parse_decimal(row["R$ desconto"]).abs
      commission  = gross_value * (channel.commission_pct / 100.0)

      order = Order.find_or_initialize_by(
        tenant: @tenant,
        order_number: row["Pedido"].to_s
      )

      order.assign_attributes(
        channel: channel,
        status: row["Status ped."].to_s,
        customer_name: row["Cliente"].to_s,
        customer_tag: parse_tag(row["Tags"].to_s),
        state: row["UF"].to_s,
        payment_method: row["Tipo pagamento"].to_s,
        gross_value: gross_value,
        cost_price: cost_price,
        freight: freight,
        discount: discount,
        commission: commission,
        weight_kg: parse_decimal(row["Peso (KG)"]),
        items_qty: row["Qtde itens"].to_i,
        ordered_at: ordered_at
      )

      order.save!
    end

    def find_or_create_channel(platform, name)
      @channels ||= {}
      @channels[platform] ||= Channel.find_or_create_by!(tenant: @tenant, platform: platform) do |c|
        c.name = name.to_s.split(" - ").last&.strip || platform.capitalize
        c.commission_pct = default_commission(platform)
        c.commission_source = "manual"
      end
    end

    def default_commission(platform)
      { "tiktok" => 6.0, "shopify" => 2.5, "yampi" => 3.0, "mercadolivre" => 14.0 }.fetch(platform, 5.0)
    end

    def parse_decimal(value)
      return 0.0 if value.nil?
      value.to_s.gsub(",", ".").to_f
    end

    def parse_date(value)
      return nil if value.nil?
      DateTime.strptime(value.to_s, "%d/%m/%Y %H:%M:%S")
    rescue Date::Error, ArgumentError
      Time.current
    end

    def parse_tag(tag)
      tag.downcase.include?("recorr") ? "recorrente" : "novo"
    end
  end
end
