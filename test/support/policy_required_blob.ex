defmodule AshStorage.Test.PolicyRequiredBlob do
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
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_primary_key :id
  end
end
