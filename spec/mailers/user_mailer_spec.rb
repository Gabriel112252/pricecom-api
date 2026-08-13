require "rails_helper"

RSpec.describe UserMailer, type: :mailer do
  let(:tenant)   { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:inviter)  { tenant.users.create!(name: "Admin", email: "admin@#{SecureRandom.hex(4)}.com", password: "password123", role: "admin") }
  let(:invitee) do
    user = tenant.users.new(name: "Convidada", email: "convidada@#{SecureRandom.hex(4)}.com")
    user.start_invitation!
    user.save!
    user
  end

  describe "#invitation_email" do
    let(:mail) { described_class.invitation_email(invitee, inviter) }

    it "addresses the invitee" do
      expect(mail.to).to eq([ invitee.email ])
    end

    it "has the expected subject" do
      expect(mail.subject).to eq("Você foi convidado para o Pricecom")
    end

    it "includes the accept-invitation link with the token" do
      # .decoded, não .encoded — o corpo bruto vem em quoted-printable e
      # quebra "=" (inclusive dentro do token) em fim de linha, o que
      # produziria falso negativo comparando string crua.
      expect(mail.text_part.decoded).to include("aceitar-convite?token=#{invitee.invitation_token}")
      expect(mail.html_part.decoded).to include("aceitar-convite?token=#{invitee.invitation_token}")
    end

    it "mentions the inviter and the tenant" do
      expect(mail.text_part.decoded).to include(inviter.name)
      expect(mail.text_part.decoded).to include(tenant.name)
    end

    # Gap conhecido e reportado: sem SMTP_ADDRESS configurado (é o caso do
    # ambiente de teste), o mailer não deve tentar entregar de verdade —
    # só loga um aviso. perform_deliveries garante isso mesmo que alguém
    # chame #deliver_now/#deliver_later em vez de só construir a mensagem.
    context "without SMTP configured" do
      it "disables actual delivery instead of raising" do
        expect(ENV["SMTP_ADDRESS"]).to be_blank
        expect { mail.deliver_now }.not_to raise_error
        expect(mail.perform_deliveries).to eq(false)
      end

      it "logs a warning with the invitation link" do
        expect(Rails.logger).to receive(:warn).with(a_string_including(invitee.email))
        mail.deliver_now
      end
    end
  end
end
