module Caisse
  class Engine < ::Rails::Engine
    isolate_namespace Caisse

    initializer "caisse.load_application_record" do
      ActiveSupport.on_load(:active_record) do
        require Rails.root.join("app/models/application_record.rb")
      end
    end

    initializer "caisse.boot" do
      puts "[Caisse] Engine chargé ✅"
    end
  end
end
