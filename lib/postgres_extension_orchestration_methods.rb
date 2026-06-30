# frozen_string_literal: true

# Predicates and ID-set queries that drive the postgres extension lifecycle.
# Included into PostgresResource; relies on `cluster_servers`,
# `representative_server`, `effective_desired_extensions`, and
# `effective_extension_config` from the host class.
module PostgresExtensionOrchestrationMethods
  # True if any cluster_server is at sync_pending for an extension whose
  # extension_config[name] reflects the currently desired version. Stale
  # extension_config (from a previous version) does not satisfy the gate.
  def should_trigger_extension_configure?
    pending_names = PostgresServerExtension.where(
      postgres_server_id: cluster_servers.map(&:id),
      state: "sync_pending",
    ).distinct.select_map(:name)
    desired = effective_desired_extensions
    pending_names.any? { |name| extension_config.dig(name, "!version") == desired[name] }
  end

  def fully_converged?
    effective_desired_extensions.all? do |name, version|
      PostgresServerExtension.where(
        postgres_server_id: cluster_servers.map(&:id),
        name:,
        installed_version: version,
        state: "ready",
      ).count == cluster_servers.count
    end
  end

  def has_stalled_extension_row?
    PostgresServerExtension
      .where(postgres_server_id: cluster_servers.map(&:id))
      .where(state: %w[pending installing sync_pending restart_pending])
      .where { last_transition_at < Time.now - 10 * 60 }
      .any?
  end

  def has_failed_extension_row?
    PostgresServerExtension
      .where(postgres_server_id: cluster_servers.map(&:id), state: "failed")
      .any?
  end

  def has_active_extension_work?
    PostgresServerExtension
      .where(postgres_server_id: cluster_servers.map(&:id))
      .where(state: %w[pending installing sync_pending restart_pending])
      .any?
  end

  def representative_install_unblocked?(name, version)
    rep = representative_server
    rep_row = PostgresServerExtension.where(postgres_server_id: rep.id, name:).first
    return false if rep_row && rep_row.state != "pending"

    non_rep_ids = cluster_servers.reject { |s| s.id == rep.id }.map(&:id)
    return true if non_rep_ids.empty?
    PostgresServerExtension.where(
      postgres_server_id: non_rep_ids,
      name:,
      installed_version: version,
      state: %w[sync_pending restart_pending ready],
    ).count == non_rep_ids.size
  end

  def restart_unblocked?(server_id, name, version)
    # RR's own rep is itself; gate against the parent's cluster.
    return parent.restart_unblocked?(server_id, name, version) if read_replica?

    rep_id = representative_server.id
    if server_id == rep_id
      # Rep restart gate: HA standbys at ready (RRs independent, excluded)
      standby_ids = servers.reject { |s| s.id == rep_id }.map(&:id)
      return true if standby_ids.empty?
      PostgresServerExtension.where(
        postgres_server_id: standby_ids,
        name:,
        installed_version: version,
        state: "ready",
      ).count == standby_ids.size
    else
      # Standby / RR restart gate: rep installed
      rep_row = PostgresServerExtension.where(postgres_server_id: rep_id, name:).first
      rep_row && %w[restart_pending ready].include?(rep_row.state) && rep_row.installed_version == version
    end
  end

  def cluster_server_ids_needing_bump
    rep_id = representative_server.id
    non_rep_ids = cluster_servers.reject { |s| s.id == rep_id }.map(&:id)

    ids = PostgresServerExtension.where(postgres_server_id: non_rep_ids)
      .exclude(state: %w[ready failed restart_pending])
      .distinct.select_map(:postgres_server_id)

    rep_active_ungated = PostgresServerExtension.where(postgres_server_id: rep_id)
      .where(state: %w[installing sync_pending]).any?
    rep_install_gate_ready = effective_desired_extensions.any? { |n, v| representative_install_unblocked?(n, v) }
    ids << rep_id if rep_active_ungated || rep_install_gate_ready

    ids
  end

  def cluster_server_ids_needing_restart
    PostgresServerExtension.where(
      postgres_server_id: cluster_servers.map(&:id),
      state: "restart_pending",
    ).all.filter_map do |row|
      version = effective_desired_extensions[row.name]
      next unless version && row.installed_version == version
      row.postgres_server_id if restart_unblocked?(row.postgres_server_id, row.name, version)
    end.uniq
  end
end
