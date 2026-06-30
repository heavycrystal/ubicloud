# frozen_string_literal: true

require_relative "../../model"

class PostgresServerExtension < Sequel::Model
  many_to_one :postgres_server, key: :postgres_server_id, read_only: true

  plugin ResourceMethods
end
