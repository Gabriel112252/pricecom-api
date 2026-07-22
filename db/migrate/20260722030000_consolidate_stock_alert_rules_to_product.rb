# Fase 2 of the stock/alerts migration: StockAlertRule goes from one row
# per product+channel to one row per product. Existing tenants may have up
# to 3 rows per product (one per StockAlertRule::CHANNELS entry) with
# different min_threshold/target_level — this migration collapses each
# group down to one row BEFORE tightening the unique index, since the new
# index can't coexist with duplicate (tenant_id, product_id) rows.
#
# Consolidation rule (explicit business decision, not a guess): keep the
# row with the SMALLEST min_threshold — the more cautious of the diverging
# values, since it fires earlier. Its target_level, automation_level ride
# along unchanged from that same row (never mixed with another row's
# values). active becomes true if ANY of the original rows was active — a
# product isn't silently unmonitored just because one of its 3 rules
# happened to be off. Where all values already agreed, there's nothing to
# decide — this is a structural merge, not a judgment call, and the row
# doesn't appear in the report.
#
# Where min_threshold OR target_level actually diverged between the
# original rows, this is a real business decision made automatically on
# your behalf — every such product is written to a CSV report in tmp/ with
# all original per-channel values, meant for manual review after this runs
# (see #write_report). This migration does not block on that review; it
# ships a safe default and flags what needs a second look.
class ConsolidateStockAlertRulesToProduct < ActiveRecord::Migration[7.2]
  class MigrationStockAlertRule < ActiveRecord::Base
    self.table_name = "stock_alert_rules"
  end

  def up
    # Must come before #consolidate! — it sets channel to NULL on the kept
    # rows, which the old NOT NULL constraint would reject.
    change_column_null :stock_alert_rules, :channel, true

    report = consolidate!
    write_report(report)

    remove_index :stock_alert_rules, column: [ :tenant_id, :product_id, :channel ]
    add_index :stock_alert_rules, [ :tenant_id, :product_id ], unique: true
  end

  def down
    remove_index :stock_alert_rules, column: [ :tenant_id, :product_id ]
    change_column_null :stock_alert_rules, :channel, false
    add_index :stock_alert_rules, [ :tenant_id, :product_id, :channel ], unique: true
    # Data cannot be un-consolidated: collapsing multiple channel rows into
    # one product row deletes the others. Restoring the original per-channel
    # rows, if ever needed, requires the CSV report #consolidate! wrote to
    # tmp/, or a database backup taken before this migration ran.
  end

  private

  def consolidate!
    report = []

    MigrationStockAlertRule.group(:tenant_id, :product_id).having("COUNT(*) > 1").count.each_key do |tenant_id, product_id|
      group = MigrationStockAlertRule.where(tenant_id: tenant_id, product_id: product_id).order(:min_threshold, :id).to_a
      keep, *drop = group

      thresholds_diverged = group.map(&:min_threshold).uniq.size > 1
      targets_diverged    = group.map(&:target_level).uniq.size > 1

      if thresholds_diverged || targets_diverged
        report << {
          tenant_id: tenant_id,
          product_id: product_id,
          kept_rule_id: keep.id,
          thresholds_diverged: thresholds_diverged,
          targets_diverged: targets_diverged,
          rows: group.map { |r|
            { id: r.id, channel: r.channel, min_threshold: r.min_threshold, target_level: r.target_level,
              automation_level: r.automation_level, active: r.active }
          }
        }
      end

      keep.update_columns(channel: nil, active: group.any?(&:active))
      MigrationStockAlertRule.where(id: drop.map(&:id)).delete_all
    end

    # Products that already had exactly one rule aren't touched by the loop
    # above (nothing to merge) but still need channel cleared to match the
    # new "informational only, not identity" shape.
    MigrationStockAlertRule.where.not(channel: nil).update_all(channel: nil)

    report
  end

  def write_report(report)
    return if report.empty?

    require "csv"
    path = Rails.root.join("tmp", "stock_alert_rules_consolidation_report_#{Time.now.utc.strftime('%Y%m%d%H%M%S')}.csv")
    CSV.open(path, "w") do |csv|
      csv << %w[tenant_id product_id kept_rule_id thresholds_diverged targets_diverged channel min_threshold target_level automation_level active]
      report.each do |entry|
        entry[:rows].each do |row|
          csv << [
            entry[:tenant_id], entry[:product_id], entry[:kept_rule_id],
            entry[:thresholds_diverged], entry[:targets_diverged],
            row[:channel], row[:min_threshold], row[:target_level], row[:automation_level], row[:active]
          ]
        end
      end
    end

    message = "[StockAlertRule migration] #{report.size} produto(s) com regras divergentes entre canais — revisar #{path}"
    Rails.logger.warn(message)
    puts message
  end
end
