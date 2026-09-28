defmodule AshStorage.Test.PolicyRequiredAttachment do
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
    blob_resource(AshStorage.Test.PolicyRequiredBlob)
    belongs_to_resource(:policy_required_post, AshStorage.Test.PolicyRequiredPost)
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_primary_key :id
  end
end
