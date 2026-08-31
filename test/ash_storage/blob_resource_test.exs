defmodule AshStorage.BlobResourceTest do
  use ExUnit.Case, async: false

  alias AshStorage.Test.Blob

  defmodule FailingDeleteService do
    @behaviour AshStorage.Service

    @impl true
    def upload(key, data, context), do: AshStorage.Service.Test.upload(key, data, context)

    @impl true
    def download(key, context), do: AshStorage.Service.Test.download(key, context)

    @impl true
    def delete(_key, _context), do: {:error, :forced_delete_failure}

    @impl true
    def exists?(key, context), do: AshStorage.Service.Test.exists?(key, context)

    @impl true
    def url(key, context), do: AshStorage.Service.Test.url(key, context)
  end

  setup do
    AshStorage.Service.Test.reset!()
    :ok
  end

  describe "attributes" do
    test "has key attribute" do
      attr = Ash.Resource.Info.attribute(Blob, :key)
      assert attr.type == Ash.Type.String
      assert attr.allow_nil? == false
    end

    test "has filename attribute" do
      attr = Ash.Resource.Info.attribute(Blob, :filename)
      assert attr.type == Ash.Type.String
      assert attr.allow_nil? == false
    end

    test "has content_type attribute" do
      attr = Ash.Resource.Info.attribute(Blob, :content_type)
      assert attr.type == Ash.Type.String
      assert attr.allow_nil? == true
    end

    test "has byte_size attribute" do
      attr = Ash.Resource.Info.attribute(Blob, :byte_size)
      assert attr.type == Ash.Type.Integer
      assert attr.allow_nil? == true
    end

    test "has checksum attribute" do
      attr = Ash.Resource.Info.attribute(Blob, :checksum)
      assert attr.type == Ash.Type.String
      assert attr.allow_nil? == true
    end

    test "has service_name attribute" do
      attr = Ash.Resource.Info.attribute(Blob, :service_name)
      assert attr.type == Ash.Type.Atom
      assert attr.allow_nil? == false
    end

    test "has metadata attribute with default" do
      attr = Ash.Resource.Info.attribute(Blob, :metadata)
      assert attr.type == Ash.Type.Map
      assert attr.default == %{}
    end
  end

  describe "actions" do
    test "has create action" do
      action = Ash.Resource.Info.action(Blob, :create)
      assert action.type == :create
    end

    test "has read action" do
      action = Ash.Resource.Info.action(Blob, :read)
      assert action.type == :read
    end

    test "has destroy action" do
      action = Ash.Resource.Info.action(Blob, :destroy)
      assert action.type == :destroy
    end

    test "has update_metadata action" do
      action = Ash.Resource.Info.action(Blob, :update_metadata)
      assert action.type == :update
      assert :metadata in action.accept
    end

    test "purge_blob destroys the row and deletes the file" do
      blob = create_blob_with_file!()

      Ash.destroy!(blob, action: :purge_blob)

      assert {:error, _} = Ash.get(Blob, blob.id)
      refute AshStorage.Service.Test.exists?(blob.key)
    end

    test "purge_blob reports a post-commit file delete failure without restoring the row" do
      blob = create_blob_with_file!(FailingDeleteService)

      assert {:error, error} = Ash.destroy(blob, action: :purge_blob)
      assert Exception.message(error) =~ "forced_delete_failure"

      assert {:error, _} = Ash.get(Blob, blob.id)
      assert AshStorage.Service.Test.exists?(blob.key)
    end
  end

  defp create_blob_with_file!(service_name \\ AshStorage.Service.Test) do
    key = "purge-#{System.unique_integer([:positive])}"
    :ok = AshStorage.Service.Test.upload(key, "purge data", AshStorage.Service.Context.new([]))

    Ash.create!(
      Blob,
      %{
        key: key,
        filename: "purge.txt",
        content_type: "text/plain",
        byte_size: 10,
        service_name: service_name,
        service_opts: %{}
      },
      action: :create
    )
  end
end
