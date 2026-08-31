defmodule AshStorage.Test.RestrictFkTestAttachment do
  @moduledoc false

  use Ash.Resource,
    domain: AshStorage.Test.PgDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStorage.AttachmentResource]

  postgres do
    table "restrict_fk_test_attachments"
    repo(AshStorage.TestRepo)
  end

  attachment do
    blob_resource(AshStorage.Test.RestrictFkTestBlob)

    belongs_to_resource(:restrict_fk_test_post, AshStorage.Test.RestrictFkTestPost,
      allow_nil?: false
    )
  end

  attributes do
    uuid_primary_key :id
  end
end
