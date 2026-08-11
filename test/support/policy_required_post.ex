defmodule AshStorage.Test.PolicyRequiredPost do
  @moduledoc false

  use Ash.Resource,
    domain: AshStorage.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStorage]

  ets do
    private? true
  end

  storage do
    service({AshStorage.Service.Test, []})
    blob_resource(AshStorage.Test.PolicyRequiredBlob)
    attachment_resource(AshStorage.Test.PolicyRequiredAttachment)

    has_one_attached(:cover_image)
    has_many_attached(:documents, dependent: :detach)
  end

  actions do
    defaults [:read, :destroy, create: [:title], update: [:title]]

    create :create_with_image do
      accept [:title]
      argument :cover_image, :file, allow_nil?: false

      change {AshStorage.Changes.HandleFileArgument,
              argument: :cover_image, attachment: :cover_image}
    end

    update :replace_image do
      require_atomic? false
      accept []
      argument :cover_image, :file, allow_nil?: false

      change {AshStorage.Changes.HandleFileArgument,
              argument: :cover_image, attachment: :cover_image}
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false
  end
end
