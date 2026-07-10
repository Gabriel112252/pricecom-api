namespace :channels do
  desc "Backfill missing Channel rows for any ChannelCredential (any tenant) that doesn't already have a " \
       "matching Channel (tenant_id + platform) — fixes order ingestion (webhook/backfill) failing with " \
       "'Canal não encontrado para provider' even though the channel looks connected and syncs products fine."
  task backfill_missing: :environment do
    created = 0
    skipped_existing = 0

    ChannelCredential.find_each do |credential|
      if Channel.exists?(tenant_id: credential.tenant_id, platform: credential.channel)
        skipped_existing += 1
        next
      end

      channel = Channel.ensure_for!(credential.tenant, credential.channel)
      created += 1
      puts "Created Channel ##{channel.id} (#{channel.name}) for tenant_id=#{credential.tenant_id} platform=#{credential.channel}"
    end

    puts "Done. #{created} Channel(s) created, #{skipped_existing} already had one."
  end
end
