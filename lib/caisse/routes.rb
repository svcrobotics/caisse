module Caisse
  class Engine < ::Rails::Engine
    isolate_namespace Caisse

    initializer "caisse.boot" do
      puts "[Caisse] Engine chargé ✅"
    end
  end
end

