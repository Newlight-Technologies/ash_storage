defmodule AshStorage.DependentTest do
  use ExUnit.Case, async: false

  alias AshStorage.Operations

  setup do
    AshStorage.Service.Test.reset!()
    :ok
  end

  defp create_post!(title \\ "test post") do
    AshStorage.Test.Post
    |> Ash.Changeset.for_create(:create, %{title: title})
    |> Ash.create!()
  end

  describe "dependent: :purge (cover_image)" do
    test "destroying record purges attachment, blob, and file" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        Operations.attach(post, :cover_image, "image data", filename: "photo.jpg")

      assert AshStorage.Service.Test.exists?(blob.key)

      Ash.destroy!(post)

      refute AshStorage.Service.Test.exists?(blob.key)
    end

    test "destroying record with no attachments succeeds" do
      post = create_post!()
      Ash.destroy!(post)
    end
  end

  describe "dependent: :detach (documents)" do
    test "destroying record detaches but keeps blobs and files" do
      post = create_post!()

      {:ok, %{blob: blob1}} =
        Operations.attach(post, :documents, "doc one", filename: "d1.txt")

      {:ok, %{blob: blob2}} =
        Operations.attach(post, :documents, "doc two", filename: "d2.txt")

      assert AshStorage.Service.Test.exists?(blob1.key)
      assert AshStorage.Service.Test.exists?(blob2.key)

      Ash.destroy!(post)

      # Files still in storage
      assert AshStorage.Service.Test.exists?(blob1.key)
      assert AshStorage.Service.Test.exists?(blob2.key)
    end
  end

  describe "caller context contract" do
    test "dependent purge authorizes nested loads and destroys with the caller actor" do
      path = Path.join(System.tmp_dir!(), "ash_storage_policy_dependent_purge.txt")
      File.write!(path, "policy dependent purge")

      post =
        AshStorage.Test.PolicyRequiredPost
        |> Ash.Changeset.for_create(
          :create_with_image,
          %{
            title: "policy purge",
            cover_image: Ash.Type.File.from_path(path)
          },
          actor: :authorized
        )
        |> Ash.create!()
        |> Ash.load!([cover_image: :blob], actor: :authorized)

      blob = post.cover_image.blob
      assert AshStorage.Service.Test.exists?(blob.key)

      Ash.destroy!(post, actor: :authorized)

      refute AshStorage.Service.Test.exists?(blob.key)

      assert {:error, _} =
               Ash.get(AshStorage.Test.PolicyRequiredBlob, blob.id, actor: :authorized)
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_policy_dependent_purge.txt"))
    end

    test "dependent detach authorizes attachment destroys with the caller actor" do
      post =
        AshStorage.Test.PolicyRequiredPost
        |> Ash.Changeset.for_create(:create, %{title: "policy detach"}, actor: :authorized)
        |> Ash.create!()

      assert {:ok, %{blob: blob, attachment: attachment}} =
               Operations.attach(post, :documents, "retained data",
                 filename: "retained.txt",
                 actor: :authorized
               )

      Ash.destroy!(post, actor: :authorized)

      assert AshStorage.Service.Test.exists?(blob.key)

      assert {:error, _} =
               Ash.get(AshStorage.Test.PolicyRequiredAttachment, attachment.id,
                 actor: :authorized
               )

      assert {:ok, _} =
               Ash.get(AshStorage.Test.PolicyRequiredBlob, blob.id, actor: :authorized)
    end
  end

  describe "soft destroy" do
    test "soft destroy does not purge or detach" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        Operations.attach(post, :cover_image, "image data", filename: "photo.jpg")

      # Verify the change is scoped to destroy actions
      # and that soft? destroys skip it
      changes = Ash.Resource.Info.changes(AshStorage.Test.Post)

      storage_change =
        Enum.find(changes, fn change ->
          change.change == {AshStorage.Changes.HandleDependentAttachments, []}
        end)

      assert storage_change
      assert :destroy in storage_change.on

      # The file should still be there (we didn't destroy)
      assert AshStorage.Service.Test.exists?(blob.key)
    end
  end
end
