# frozen_string_literal: true

require "active_record"
require_relative "caisse/version"
require_relative "caisse/engine"

module Caisse
  class Error < StandardError; end
end
