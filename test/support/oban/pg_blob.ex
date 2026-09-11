defmodule AshStorage.Test.PgBlob do
  @moduledoc false
  use Ash.Resource,
    domain: AshStorage.Test.PgDomain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStorage.BlobResource, AshOban]

  postgres do
    table "storage_blobs"
    repo(AshStorage.TestRepo)
  end

  blob do
  end

  policies do
    policy always() do
      authorize_if always()
    end

    policy [action(:update_metadata), actor_attribute_equals(:deny_analyzer_target?, true)] do
      forbid_if expr(pending_analyzers == true)
      authorize_if always()
    end
  end

  oban do
    triggers do
      trigger :run_pending_analyzers do
        actor_persister(AshStorage.Test.AnalyzerActorPersister)
        action :run_pending_analyzers
        on_error(:fail_pending_analyzers)
        on_error_fails_job?(true)
        read_action :read
        where expr(pending_analyzers == true)
        scheduler_cron("* * * * *")
        max_attempts(3)
        scheduler_module_name(AshStorage.Test.PgBlob.RunPendingAnalyzersScheduler)
        worker_module_name(AshStorage.Test.PgBlob.RunPendingAnalyzersWorker)
      end

      trigger :purge_blob do
        action :purge_blob
        read_action :read
        where expr(pending_purge == true)
        scheduler_cron("* * * * *")
        max_attempts(3)
        scheduler_module_name(AshStorage.Test.PgBlob.PurgeBlobScheduler)
        worker_module_name(AshStorage.Test.PgBlob.PurgeBlobWorker)
      end

      trigger :run_pending_variants do
        action :run_pending_variants
        read_action :read
        where expr(pending_variants == true)
        scheduler_cron("* * * * *")
        max_attempts(3)
        scheduler_module_name(AshStorage.Test.PgBlob.RunPendingVariantsScheduler)
        worker_module_name(AshStorage.Test.PgBlob.RunPendingVariantsWorker)
      end
    end
  end

  attributes do
    uuid_primary_key :id
  end
end
