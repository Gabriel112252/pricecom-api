require "rails_helper"

RSpec.describe User, type: :model do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }

  describe "cadastro direto" do
    it "requires a password" do
      user = tenant.users.new(name: "Ana", email: "ana@#{SecureRandom.hex(4)}.com")
      expect(user).not_to be_valid
      expect(user.errors[:password]).to be_present
    end

    it "requires the password to be at least 8 characters" do
      user = tenant.users.new(name: "Ana", email: "ana@#{SecureRandom.hex(4)}.com", password: "short")
      expect(user).not_to be_valid
      expect(user.errors[:password]).to be_present
    end

    it "is valid with a name, unique email and password" do
      user = tenant.users.new(name: "Ana", email: "ana@#{SecureRandom.hex(4)}.com", password: "password123")
      expect(user).to be_valid
    end
  end

  describe "convite" do
    it "does not require a password when invited" do
      user = tenant.users.new(name: "Ana", email: "ana@#{SecureRandom.hex(4)}.com")
      user.start_invitation!

      expect(user).to be_valid
      expect(user.save).to eq(true)
    end

    it "sets active to false and generates a token" do
      user = tenant.users.new(name: "Ana", email: "ana@#{SecureRandom.hex(4)}.com")
      user.start_invitation!
      user.save!

      expect(user.active).to eq(false)
      expect(user.invitation_token).to be_present
      expect(user.invitation_sent_at).to be_present
      expect(user.invited?).to eq(true)
      expect(user.invitation_pending?).to eq(true)
    end

    it "does not fail validation when updating an invited user that still has no password (e.g. changing role)" do
      user = tenant.users.new(name: "Ana", email: "ana@#{SecureRandom.hex(4)}.com")
      user.start_invitation!
      user.save!

      user.role = "admin"
      expect(user.save).to eq(true)
    end

    it "expires after 7 days" do
      user = tenant.users.new(name: "Ana", email: "ana@#{SecureRandom.hex(4)}.com")
      user.start_invitation!
      user.save!
      user.update_column(:invitation_sent_at, 8.days.ago)

      expect(user.invitation_expired?).to eq(true)
    end

    it "is not expired within the 7-day window" do
      user = tenant.users.new(name: "Ana", email: "ana@#{SecureRandom.hex(4)}.com")
      user.start_invitation!
      user.save!
      user.update_column(:invitation_sent_at, 6.days.ago)

      expect(user.invitation_expired?).to eq(false)
    end

    it "accept_invitation! sets the password, activates and marks accepted" do
      user = tenant.users.new(name: "Ana", email: "ana@#{SecureRandom.hex(4)}.com")
      user.start_invitation!
      user.save!

      expect(user.accept_invitation!("novaSenha123")).to eq(true)
      user.reload
      expect(user.active).to eq(true)
      expect(user.invitation_accepted_at).to be_present
      expect(user.authenticate("novaSenha123")).to be_truthy
    end
  end

  it "restricts role to admin/operador" do
    user = tenant.users.new(name: "Ana", email: "ana@#{SecureRandom.hex(4)}.com", password: "password123")
    expect { user.role = "superadmin" }.to raise_error(ArgumentError)
  end

  describe "mcp_api_key" do
    it "is generated automatically on create, unique per user" do
      user = tenant.users.create!(name: "Ana", email: "ana@#{SecureRandom.hex(4)}.com", password: "password123")
      other = tenant.users.create!(name: "Beto", email: "beto@#{SecureRandom.hex(4)}.com", password: "password123")

      expect(user.mcp_api_key).to be_present
      expect(user.mcp_api_key).not_to eq(other.mcp_api_key)
    end

    it "regenerate_mcp_api_key! rotates the token, invalidating the previous one" do
      user = tenant.users.create!(name: "Ana", email: "ana@#{SecureRandom.hex(4)}.com", password: "password123")
      previous = user.mcp_api_key

      user.regenerate_mcp_api_key!

      expect(user.mcp_api_key).not_to eq(previous)
      expect(User.find_by(mcp_api_key: previous)).to be_nil
    end
  end

  describe "#deactivate! / #reactivate!" do
    let(:admin) { tenant.users.create!(name: "Admin", email: "admin@#{SecureRandom.hex(4)}.com", password: "password123", role: "admin") }

    it "blocks self-deactivation, returning false instead of raising" do
      expect(admin.deactivate!(actor: admin)).to eq(false)
      expect(admin.reload.active).to eq(true)
    end

    it "allows deactivating a different user" do
      target = tenant.users.create!(name: "Alvo", email: "alvo@#{SecureRandom.hex(4)}.com", password: "password123")
      expect(target.deactivate!(actor: admin)).to eq(true)
      expect(target.reload.active).to eq(false)
    end

    it "reactivate! has no self-lockout restriction" do
      admin.update!(active: false)
      expect(admin.reactivate!).to eq(true)
      expect(admin.reload.active).to eq(true)
    end
  end
end
