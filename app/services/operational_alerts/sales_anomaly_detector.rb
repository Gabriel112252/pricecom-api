module OperationalAlerts
  class SalesAnomalyDetector
    WINDOW = 60.minutes
    BASELINE_WEEKS = (1..4).to_a.freeze
    DROP_THRESHOLD = 0.50
    CRITICAL_DROP_THRESHOLD = 0.75
    MIN_POSITIVE_BASELINES = 3
    MIN_EXPECTED_ORDERS = 10.0
    MIN_ORDER_GAP = 5.0
    MIN_EXPECTED_SKU_UNITS = 5.0
    MIN_SKU_GAP = 3.0

    def self.call(tenant, now: Time.current)
      new(tenant, now: now).call
    end

    def initialize(tenant, now: Time.current)
      @tenant = tenant
      @now = now
      @channels = tenant.channels.where(active: true).pluck(:id, :name, :platform)
      @channel_ids = @channels.map(&:first)
    end

    def call
      return { order_alerts: 0, sku_alerts: 0 } if channel_ids.empty?

      current_range = (now - WINDOW)..now
      baseline_ranges = BASELINE_WEEKS.map do |weeks_ago|
        ((now - weeks_ago.weeks) - WINDOW)..(now - weeks_ago.weeks)
      end

      current_order_counts = order_counts_by_channel(current_range)
      baseline_order_counts = baseline_ranges.map { |range| order_counts_by_channel(range) }
      order_alerts = detect_order_volume(current_order_counts, baseline_order_counts)

      # SKU continua sendo detectado pelo total da loja para nao multiplicar
      # alertas por canal. Ao mesmo tempo guardamos o detalhamento por canal
      # no metadata, porque o mesmo SKU pode vender em Yampi, TikTok etc. e o
      # operador precisa saber de onde a queda veio.
      current_sku_channel_counts = sku_unit_counts_by_channel(current_range)
      baseline_sku_channel_counts = baseline_ranges.map { |range| sku_unit_counts_by_channel(range) }
      current_sku_counts = aggregate_sku_counts(current_sku_channel_counts)
      baseline_sku_counts = baseline_sku_channel_counts.map { |counts| aggregate_sku_counts(counts) }
      sku_alerts = detect_sku_volume(
        current_sku_counts,
        baseline_sku_counts,
        current_sku_channel_counts,
        baseline_sku_channel_counts
      )

      { order_alerts: order_alerts, sku_alerts: sku_alerts }
    end

    private

    attr_reader :tenant, :now, :channels, :channel_ids

    def sales_scope(range)
      tenant.orders
        .sales
        .not_canceled
        .revenue_countable
        .where(channel_id: channel_ids)
        .where(ordered_at: range)
    end

    def order_counts_by_channel(range)
      sales_scope(range).group(:channel_id).count.transform_values(&:to_f)
    end

    def sku_unit_counts_by_channel(range)
      sales_scope(range)
        .joins(:order_items)
        .where(order_items: { is_gift: false })
        .where("order_items.sku IS NOT NULL AND order_items.sku <> ''")
        .group("orders.channel_id", "order_items.sku")
        .sum("order_items.quantity")
        .each_with_object({}) do |((channel_id, sku), quantity), result|
          result[[channel_id, sku]] = quantity.to_f
        end
    end

    def aggregate_sku_counts(channel_counts)
      channel_counts.each_with_object(Hash.new(0.0)) do |((_channel_id, sku), quantity), result|
        result[sku] += quantity.to_f
      end
    end

    def detect_order_volume(current_counts, baseline_counts)
      triggered_scope_keys = []

      all_samples = baseline_counts.map { |counts| counts.values.sum }
      all_current = current_counts.values.sum
      if anomaly?(current: all_current, samples: all_samples, min_expected: MIN_EXPECTED_ORDERS, min_gap: MIN_ORDER_GAP)
        upsert_order_alert(
          scope_key: "all",
          channel_id: nil,
          channel_name: "Todos os canais",
          current: all_current,
          samples: all_samples
        )
        triggered_scope_keys << "all"
      end

      channels.each do |channel_id, channel_name, platform|
        samples = baseline_counts.map { |counts| counts.fetch(channel_id, 0).to_f }
        current = current_counts.fetch(channel_id, 0).to_f
        next unless anomaly?(current: current, samples: samples, min_expected: MIN_EXPECTED_ORDERS, min_gap: MIN_ORDER_GAP)

        scope_key = "channel:#{channel_id}"
        upsert_order_alert(
          scope_key: scope_key,
          channel_id: channel_id,
          channel_name: channel_name.presence || platform.to_s,
          current: current,
          samples: samples
        )
        triggered_scope_keys << scope_key
      end

      resolve_untriggered("order_volume_drop", triggered_scope_keys) { |conflict| conflict.metadata.to_h["scope_key"] }
      triggered_scope_keys.length
    end

    def detect_sku_volume(current_counts, baseline_counts, current_channel_counts, baseline_channel_counts)
      triggered_skus = []
      baseline_skus = baseline_counts.flat_map(&:keys).uniq
      products_by_sku = tenant.products.where(sku: baseline_skus).index_by(&:sku)

      baseline_skus.each do |sku|
        samples = baseline_counts.map { |counts| counts.fetch(sku, 0).to_f }
        current = current_counts.fetch(sku, 0).to_f
        next unless anomaly?(current: current, samples: samples, min_expected: MIN_EXPECTED_SKU_UNITS, min_gap: MIN_SKU_GAP)

        channel_breakdown = sku_channel_breakdown(
          sku,
          current_channel_counts,
          baseline_channel_counts
        )

        upsert_sku_alert(
          product: products_by_sku[sku],
          sku: sku,
          current: current,
          samples: samples,
          channel_breakdown: channel_breakdown
        )
        triggered_skus << sku
      end

      resolve_untriggered("sku_volume_drop", triggered_skus) { |conflict| conflict.metadata.to_h["sku"] }
      triggered_skus.length
    end

    def sku_channel_breakdown(sku, current_counts, baseline_counts)
      channels.filter_map do |channel_id, channel_name, platform|
        samples = baseline_counts.map { |counts| counts.fetch([ channel_id, sku ], 0).to_f }
        current = current_counts.fetch([ channel_id, sku ], 0).to_f
        expected = median(samples)
        next if expected <= 0 && current <= 0

        {
          channel_id: channel_id,
          channel_name: channel_name.presence || platform.to_s,
          current: current.round(2),
          expected: expected.round(2),
          drop_pct: drop_pct(current, expected),
          affected: anomaly?(
            current: current,
            samples: samples,
            min_expected: MIN_EXPECTED_SKU_UNITS,
            min_gap: MIN_SKU_GAP
          )
        }
      end.sort_by { |row| [ row[:affected] ? 0 : 1, -row[:expected].to_f ] }
    end

    def anomaly?(current:, samples:, min_expected:, min_gap:)
      return false if samples.count(&:positive?) < MIN_POSITIVE_BASELINES

      expected = median(samples)
      return false if expected < min_expected
      return false if (expected - current) < min_gap

      current <= expected * (1.0 - DROP_THRESHOLD)
    end

    def median(values)
      sorted = values.map(&:to_f).sort
      middle = sorted.length / 2
      return sorted[middle] if sorted.length.odd?

      (sorted[middle - 1] + sorted[middle]) / 2.0
    end

    def drop_pct(current, expected)
      return 0.0 if expected <= 0

      ((1.0 - (current.to_f / expected.to_f)) * 100.0).clamp(0.0, 100.0).round(1)
    end

    def severity_for(current, expected, kind:)
      drop = drop_pct(current, expected)
      return "critical" if drop >= (CRITICAL_DROP_THRESHOLD * 100) && (kind == :orders || expected >= 10)

      kind == :orders ? "high" : "medium"
    end

    def upsert_order_alert(scope_key:, channel_id:, channel_name:, current:, samples:)
      expected = median(samples)
      conflict = tenant.audit_conflicts
        .open
        .where(conflict_type: "order_volume_drop")
        .where("metadata ->> 'scope_key' = ?", scope_key)
        .first
      conflict ||= tenant.audit_conflicts.new(conflict_type: "order_volume_drop", status: "open")

      conflict.assign_attributes(
        severity: severity_for(current, expected, kind: :orders),
        expected_value: expected.round(2),
        actual_value: current.round(2),
        difference: (current - expected).round(2),
        source: "auto",
        metadata: {
          scope_key: scope_key,
          channel_id: channel_id,
          channel_name: channel_name,
          window_minutes: (WINDOW / 1.minute).to_i,
          baseline_weeks: BASELINE_WEEKS,
          baseline_samples: samples.map { |value| value.round(2) },
          drop_pct: drop_pct(current, expected),
          last_checked_at: now.iso8601
        }
      )
      conflict.save!
    end

    def upsert_sku_alert(product:, sku:, current:, samples:, channel_breakdown:)
      expected = median(samples)
      conflict = tenant.audit_conflicts
        .open
        .where(conflict_type: "sku_volume_drop")
        .where("metadata ->> 'sku' = ?", sku.to_s)
        .first
      conflict ||= tenant.audit_conflicts.new(conflict_type: "sku_volume_drop", status: "open")

      conflict.assign_attributes(
        product: product,
        severity: severity_for(current, expected, kind: :sku),
        expected_value: expected.round(2),
        actual_value: current.round(2),
        difference: (current - expected).round(2),
        source: "auto",
        metadata: {
          sku: sku,
          product_name: product&.name,
          channel_breakdown: channel_breakdown,
          window_minutes: (WINDOW / 1.minute).to_i,
          baseline_weeks: BASELINE_WEEKS,
          baseline_samples: samples.map { |value| value.round(2) },
          drop_pct: drop_pct(current, expected),
          last_checked_at: now.iso8601
        }
      )
      conflict.save!
    end

    def resolve_untriggered(conflict_type, triggered_keys)
      tenant.audit_conflicts.open.where(conflict_type: conflict_type).find_each do |conflict|
        key = yield(conflict)
        next if triggered_keys.include?(key)

        conflict.update!(status: "resolved", resolved_at: now, resolved_by: nil)
      end
    end
  end
end
