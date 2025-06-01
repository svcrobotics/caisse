# app/models/caisse/remboursement.rb
module Caisse
  class Remboursement < ::ApplicationRecord
    self.table_name = "remboursements"
    belongs_to :vente, class_name: "Caisse::Vente"
  end
end