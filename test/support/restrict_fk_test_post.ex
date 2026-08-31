defmodule AshStorage.Test.RestrictFkTestPost do
  @moduledoc false

  use Ash.Resource,
    domain: AshStorage.Test.PgDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStorage]

  postgres do
    table "restrict_fk_test_posts"
    repo(AshStorage.TestRepo)
  end

  storage do
    service({AshStorage.Service.Test, []})
    blob_resource(AshStorage.Test.RestrictFkTestBlob)
    attachment_resource(AshStorage.Test.RestrictFkTestAttachment)

    has_one_attached(:cover_image)
  end

  actions do
    defaults [:read, :destroy, create: [:title]]

    update :replace_image do
      require_atomic? false
      accept []
      argument :cover_image, :file, allow_nil?: false

      change {AshStorage.Changes.HandleFileArgument,
              argument: :cover_image, attachment: :cover_image}
    end

    update :replace_image_then_fail do
      require_atomic? false
      accept []
      argument :cover_image, :file, allow_nil?: false

      change {AshStorage.Changes.HandleFileArgument,
              argument: :cover_image, attachment: :cover_image}

      change AshStorage.Test.FailAfterAction
    end

    destroy :destroy_then_fail do
      require_atomic? false
      change AshStorage.Test.FailAfterAction
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false
  end
end
