class User < ApplicationRecord
  belongs_to :tenant

  # validations: false — o convidado (Api::V1::UsersController#create com
  # invite: true) nasce sem senha, só com invitation_token; a validação
  # automática do has_secure_password rejeitaria esse registro (e qualquer
  # update nele, tipo mudar role) por password_digest estar em branco.
  # #password_required? abaixo cobre exatamente os casos em que uma senha É
  # obrigatória.
  has_secure_password validations: false

  enum :role, { operador: "operador", admin: "admin" }, default: "operador"

  INVITATION_EXPIRATION = 7.days

  validates :email, presence: true, uniqueness: { scope: :tenant_id }
  validates :name, presence: true
  validates :password, presence: true, length: { minimum: 8 }, if: :password_required?

  before_create :generate_mcp_api_key

  scope :active, -> { where(active: true) }

  def invited?
    invitation_token.present?
  end

  def invitation_pending?
    invited? && invitation_accepted_at.blank?
  end

  def invitation_expired?
    invitation_sent_at.blank? || invitation_sent_at < INVITATION_EXPIRATION.ago
  end

  # Gera o token e deixa o registro pronto pra ser salvo pelo controller —
  # mesmo estilo do Tenant#regenerate_tv_token! (token opaco via
  # SecureRandom, guardado em claro, mesma convenção já usada em
  # tv_token/testimonials_public_token neste projeto).
  def start_invitation!
    self.invitation_token = SecureRandom.urlsafe_base64(32)
    self.invitation_sent_at = Time.current
    self.active = false
  end

  # Chamado só depois de validar o token fora daqui (ver
  # Api::V1::UsersController#accept_invitation) — não repete a checagem de
  # expiração/uso, só executa a transição de estado.
  def accept_invitation!(new_password)
    update(
      password: new_password,
      invitation_accepted_at: Time.current,
      active: true
    )
  end

  # Token único por usuário pro servidor MCP (mesmo padrão do ScrumFlow,
  # ~/projetos/scrumflow/back/app/models/user.rb:99-110) — não é o JWT da
  # sessão web: de vida longa, revogável à parte, pra um cliente MCP
  # (Claude Desktop, Claude.ai) não precisar reautenticar toda hora.
  # Regenerar invalida o anterior imediatamente (mesma coluna é sobrescrita).
  def regenerate_mcp_api_key!
    update!(mcp_api_key: SecureRandom.hex(32))
  end

  # Ponto único da regra "admin não pode se auto-desativar" — chamado tanto
  # por Api::V1::UsersController#destroy quanto por AtivarDesativarUsuarioTool
  # (MCP), pra a trava de lockout não ficar duplicada em dois lugares.
  # Retorna false (sem levantar) quando bloqueado, pra cada chamador decidir
  # como responder (403 JSON vs. mensagem de tool).
  def deactivate!(actor:)
    return false if actor == self

    update!(active: false)
    true
  end

  def reactivate!
    update!(active: true)
    true
  end

  private

  # Senha obrigatória em dois casos: cadastro direto (create sem convite),
  # e qualquer momento em que uma senha está de fato sendo definida (accept
  # de convite, troca de senha futura) — nunca em updates que não mexem em
  # password (ex: trocar role de um convite ainda pendente, sem
  # password_digest nenhum).
  def password_required?
    new_record? ? !invited? : password.present?
  end

  def generate_mcp_api_key
    self.mcp_api_key ||= SecureRandom.hex(32)
  end
end
