defmodule AshStorage.Test.PgPost do
  @moduledoc false
  use Ash.Resource,
    domain: AshStorage.Test.PgDomain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStorage]

  postgres do
    table "posts"
    repo(AshStorage.TestRepo)
  end

  storage do
    service({AshStorage.Service.Test, []})
    blob_resource(AshStorage.Test.PgBlob)
    attachment_resource(AshStorage.Test.PgAttachment)

    has_one_attached :cover_image do
      variant(:eager_upper, AshStorage.Test.UppercaseVariant, generate: :eager)
      variant(:oban_upper, AshStorage.Test.UppercaseVariant, generate: :oban)
    end

    has_many_attached(:documents, dependent: :detach)

    has_one_attached :analyzed_document do
      analyzer(AshStorage.Test.TitleAnalyzer,
        analyze: :oban,
        write_attributes: [extracted_title: :title]
      )
    end

    has_one_attached :raising_document do
      analyzer(AshStorage.Test.RaisingAnalyzer)
    end

    has_one_attached :cleanup_document do
      analyzer({AshStorage.Test.CleanupFailureAnalyzer, test_key: "file-argument"})
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
  end

  policies do
    policy always() do
      authorize_if always()
    end

    policy [action(:update), actor_attribute_equals(:restricted?, true)] do
      authorize_if actor_attribute_equals(:role, :editor)
    end
  end

  actions do
    defaults [:read, :destroy, create: [:title], update: [:title]]

    create :create_with_analyzed_document do
      accept [:title]
      argument :file, Ash.Type.File, allow_nil?: false

      change {AshStorage.Changes.HandleFileArgument,
              argument: :file, attachment: :analyzed_document}
    end

    create :create_with_raising_document do
      accept [:title]
      argument :file, Ash.Type.File, allow_nil?: false

      change {AshStorage.Changes.HandleFileArgument,
              argument: :file, attachment: :raising_document}
    end

    create :create_with_cleanup_document do
      accept [:title]
      argument :file, Ash.Type.File, allow_nil?: false

      change {AshStorage.Changes.HandleFileArgument,
              argument: :file, attachment: :cleanup_document}
    end

    update :attach_cover_image_then_fail do
      require_atomic? false
      accept []
      argument :io, :term, allow_nil?: false
      argument :filename, :string, allow_nil?: false
      argument :content_type, :string, default: "application/octet-stream"
      argument :metadata, :map, default: %{}

      change {AshStorage.Changes.Attach, attachment_name: :cover_image}
      change AshStorage.Test.FailAfterAction
    end

    update :attach_cover_image_blob do
      require_atomic? false
      accept []
      argument :cover_image_blob_id, :uuid, allow_nil?: false

      change {AshStorage.Changes.AttachBlob,
              argument: :cover_image_blob_id, attachment: :cover_image}
    end

    update :attach_cover_image_blob_then_fail do
      require_atomic? false
      accept []
      argument :cover_image_blob_id, :uuid, allow_nil?: false

      change {AshStorage.Changes.AttachBlob,
              argument: :cover_image_blob_id, attachment: :cover_image}

      change AshStorage.Test.FailAfterAction
    end
  end
end
