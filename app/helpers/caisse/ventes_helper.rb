module Caisse::VentesHelper
  def statut_blockchain
    Blockchain::Service.chain.valid? ? "✅ Blockchain valide" : "❌ Blockchain corrompue"
  end
end
