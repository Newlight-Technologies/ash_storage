defmodule AshStorage.Test.PgPost do
  @moduledoc false
  use Ash.Resource,
    domain: AshStorage.Test.PgDomain,
    data_layer: AshPostgres.DataLayer,
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
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read, :destroy, create: [:title], update: [:title]]

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
  end
end
