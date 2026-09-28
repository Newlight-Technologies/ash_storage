defmodule AshStorage.Test.ContextPolicyBlob do
  @moduledoc false

  use Ash.Resource,
    domain: AshStorage.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStorage.BlobResource]

  ets do
    private? true
  end

  blob do
  end

  policies do
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    policy action_type(:read) do
      forbid_unless actor_present()
      authorize_if expr(filename != "hidden.txt")
    end

    policy action_type([:create, :update, :destroy]) do
      access_type :strict
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_primary_key :id
  end
end

defmodule AshStorage.Test.ContextPolicyAttachment do
  @moduledoc false

  use Ash.Resource,
    domain: AshStorage.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStorage.AttachmentResource]

  ets do
    private? true
  end

  attachment do
    blob_resource(AshStorage.Test.ContextPolicyBlob)
    belongs_to_resource(:context_policy_post, AshStorage.Test.ContextPolicyPost)
  end

  policies do
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if expr(name == ^actor(:visible_name))
    end

    policy action_type(:create) do
      access_type :strict
      authorize_if actor_attribute_equals(:role, :storage)
      authorize_if actor_attribute_equals(:role, :create_only)
    end

    policy action_type(:destroy) do
      access_type :strict
      authorize_if actor_attribute_equals(:role, :storage)
    end
  end

  attributes do
    uuid_primary_key :id
  end
end

defmodule AshStorage.Test.ContextPolicyPost do
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
    blob_resource(AshStorage.Test.ContextPolicyBlob)
    attachment_resource(AshStorage.Test.ContextPolicyAttachment)

    has_one_attached(:cover_image)
    has_many_attached(:documents, dependent: :detach)
  end

  actions do
    defaults [:read, :destroy, create: [:title], update: [:title]]

    create :create_with_file do
      accept [:title]
      argument :cover_image, :file, allow_nil?: false

      change {AshStorage.Changes.AttachFile, argument: :cover_image, attachment: :cover_image}
    end

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

    update :attach_blob do
      require_atomic? false
      accept []
      argument :cover_image_blob_id, :uuid, allow_nil?: false

      change {AshStorage.Changes.AttachBlob,
              argument: :cover_image_blob_id, attachment: :cover_image}
    end
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false
  end
end
