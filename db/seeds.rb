tenant = Tenant.find_or_create_by!(slug: "hidrabene") do |t|
  t.name = "Hidrabene"
  t.plan = "starter"
end

user = User.find_or_create_by!(email: "admin@hidrabene.com", tenant: tenant) do |u|
  u.name     = "Admin"
  u.password = "password123"
  u.role     = "admin"
end

puts "Seed concluído: tenant=#{tenant.slug}, user=#{user.email}"
