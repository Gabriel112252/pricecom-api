class UserMailer < ApplicationMailer
  # Resend (e a maioria dos providers transacionais) rejeita remetente de
  # domínio não verificado — ApplicationMailer#default from ainda é o
  # placeholder "from@example.com" do gerador do Rails. MAIL_FROM_ADDRESS
  # não fazia parte da lista de env vars pedida (só as 5 de SMTP_*), mas
  # sem um remetente de verdade nenhum e-mail sai mesmo com SMTP correto —
  # ver nota no relatório final sobre configurar isso junto com a conta
  # Resend.
  default from: -> { ENV.fetch("MAIL_FROM_ADDRESS", "no-reply@pricecom.com") }

  # user: convidado (já com invitation_token setado por User#start_invitation!,
  # ainda não persistido o suficiente pra isso mudar — chamado depois do save).
  # inviter: quem disparou o convite (current_user do controller) — só pro
  # corpo do e-mail ("Fulano te convidou"), opcional porque nem toda chamada
  # futura desse mailer precisa ter um inviter humano (ex: reenvio automático).
  def invitation_email(user, inviter = nil)
    @user = user
    @inviter = inviter
    @tenant = user.tenant
    @accept_url = "#{ENV['FRONTEND_URL']}/aceitar-convite?token=#{user.invitation_token}"

    # Sem SMTP configurado (dev, ou produção antes da conta Resend estar
    # pronta) não quebra o fluxo de criação do usuário — quem chamou isso já
    # está em deliver_later, então esse warning some no log do worker, não
    # trava a request. A action ainda "roda" (renderiza a view, monta o
    # Mail::Message) só pra deixar o link acessível no log em dev.
    unless smtp_configured?
      Rails.logger.warn(
        "[UserMailer] SMTP não configurado — convite para #{user.email} não foi enviado. " \
        "Link (copie manualmente pra testar): #{@accept_url}"
      )
      self.perform_deliveries = false
    end

    mail(to: user.email, subject: "Você foi convidado para o Pricecom")
  end

  private

  def smtp_configured?
    ENV["SMTP_ADDRESS"].present?
  end
end
