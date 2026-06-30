# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:postgres_resource) do
      add_column :desired_extensions, :jsonb, null: false, default: "{}"
      add_column :extension_config, :jsonb, null: false, default: "{}"
      add_constraint(:desired_extensions_root_only, Sequel.lit("parent_id IS NULL OR restore_target IS NOT NULL OR desired_extensions = '{}'::jsonb"))
      add_constraint(:extension_config_root_only, Sequel.lit("parent_id IS NULL OR restore_target IS NOT NULL OR extension_config = '{}'::jsonb"))
    end

    create_table(:postgres_server_extension) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(733)") # UBID.to_base32_n("px") => 733
      foreign_key :postgres_server_id, :postgres_server, type: :uuid, null: false, on_delete: :cascade
      column :name, :text, null: false
      column :installed_version, :text
      column :state, :text, null: false, default: "pending"
      DateTime :last_transition_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :last_error, :text
      unique [:postgres_server_id, :name]
    end

    run <<~SQL
      CREATE FUNCTION reset_postgres_server_extension_on_version_change() RETURNS TRIGGER LANGUAGE plpgsql AS $$
        BEGIN
          UPDATE postgres_server_extension
          SET state = 'pending', last_transition_at = NOW(), last_error = NULL
          WHERE state IN ('ready', 'failed')
            AND (NEW.desired_extensions ? name)
            AND COALESCE(installed_version, '') <> (NEW.desired_extensions ->> name)
            AND postgres_server_id IN (
              SELECT id FROM postgres_server WHERE resource_id = NEW.id
                OR resource_id IN (SELECT id FROM postgres_resource WHERE parent_id = NEW.id AND restore_target IS NULL)
            );
          RETURN NEW;
        END;
      $$
    SQL

    run <<~SQL
      CREATE TRIGGER postgres_resource_desired_extensions_reset
      AFTER UPDATE OF desired_extensions ON postgres_resource
      FOR EACH ROW WHEN (OLD.desired_extensions IS DISTINCT FROM NEW.desired_extensions)
      EXECUTE FUNCTION reset_postgres_server_extension_on_version_change()
    SQL
  end

  down do
    run "DROP TRIGGER IF EXISTS postgres_resource_desired_extensions_reset ON postgres_resource"
    run "DROP FUNCTION IF EXISTS reset_postgres_server_extension_on_version_change()"

    alter_table(:postgres_resource) do
      drop_constraint(:desired_extensions_root_only)
      drop_constraint(:extension_config_root_only)
      drop_column :desired_extensions
      drop_column :extension_config
    end

    drop_table(:postgres_server_extension)
  end
end
