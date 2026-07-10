namespace :data_source_configs do
  desc "Seed default DataSourceConfig rows (cost/tax/freight -> idworks, payment_reconciliation -> pagarme) " \
       "for any tenant that already has idworks/Pagar.me connected but connected before DataSourceConfig " \
       "existed. Never overwrites a data_type a tenant has already configured."
  task seed_defaults: :environment do
    created = 0

    Tenant.find_each do |tenant|
      if tenant.integrations.exists?(provider: "idworks")
        created += DataSourceConfig.ensure_defaults_for_source!(tenant, "idworks").count(&:previously_new_record?)
      end

      if tenant.financial_sources.exists?(provider: "pagarme")
        created += DataSourceConfig.ensure_defaults_for_source!(tenant, "pagarme").count(&:previously_new_record?)
      end
    end

    puts "Done. #{created} DataSourceConfig row(s) created."
  end
end
