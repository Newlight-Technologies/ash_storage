defmodule AshStorage.Test.RestrictFkTestBlob do
  @moduledoc false

  use Ash.Resource,
    domain: AshStorage.Test.PgDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStorage.BlobResource]

  postgres do
    table "restrict_fk_test_blobs"
    repo(AshStorage.TestRepo)
  end

  blob do
  end

  attributes do
    uuid_primary_key :id
  end
end
