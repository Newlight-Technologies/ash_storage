defmodule AshStorage.FileArgumentTest do
  use ExUnit.Case, async: false

  setup do
    AshStorage.Service.Test.reset!()
    :ok
  end

  describe "create with :file argument" do
    test "attaches file on create" do
      path = Path.join(System.tmp_dir!(), "ash_storage_create_test.txt")
      File.write!(path, "hello from create")

      post =
        AshStorage.Test.Post
        |> Ash.Changeset.for_create(:create_with_image, %{
          title: "with image",
          cover_image: Ash.Type.File.from_path(path)
        })
        |> Ash.create!()

      post = Ash.load!(post, cover_image: :blob)
      assert post.cover_image != nil
      assert post.cover_image.blob.filename

      assert {:ok, "hello from create"} =
               AshStorage.Service.Test.download(post.cover_image.blob.key, [])
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_create_test.txt"))
    end

    test "skips attach when argument is nil" do
      post =
        AshStorage.Test.Post
        |> Ash.Changeset.for_create(:create_with_image, %{title: "no image"})
        |> Ash.create!()

      post = Ash.load!(post, :cover_image)
      assert post.cover_image == nil
    end

    test "forwards action opts to the nested attach operation" do
      path = Path.join(System.tmp_dir!(), "ash_storage_actor_opts_test.txt")
      File.write!(path, "actor opts")

      post =
        AshStorage.Test.ActorRequiredPost
        |> Ash.Changeset.for_create(
          :create_with_image,
          %{
            title: "with actor",
            cover_image: Ash.Type.File.from_path(path)
          },
          actor: :authorized
        )
        |> Ash.create!()

      post = Ash.load!(post, cover_image: :blob)

      assert {:ok, "actor opts"} = AshStorage.Service.Test.download(post.cover_image.blob.key, [])
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_actor_opts_test.txt"))
    end

    test "forwards action opts to nested attach operations during bulk create" do
      path1 = Path.join(System.tmp_dir!(), "ash_storage_bulk_actor_opts_1.txt")
      path2 = Path.join(System.tmp_dir!(), "ash_storage_bulk_actor_opts_2.txt")

      File.write!(path1, "bulk actor opts 1")
      File.write!(path2, "bulk actor opts 2")

      result =
        Ash.bulk_create(
          [
            %{title: "bulk 1", cover_image: Ash.Type.File.from_path(path1)},
            %{title: "bulk 2", cover_image: Ash.Type.File.from_path(path2)}
          ],
          AshStorage.Test.ActorRequiredPost,
          :create_with_image,
          actor: :authorized,
          return_records?: true,
          return_errors?: true
        )

      assert result.status == :success
      assert [post1, post2] = Ash.load!(result.records, cover_image: :blob)

      assert {:ok, "bulk actor opts 1"} =
               AshStorage.Service.Test.download(post1.cover_image.blob.key, [])

      assert {:ok, "bulk actor opts 2"} =
               AshStorage.Service.Test.download(post2.cover_image.blob.key, [])
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_bulk_actor_opts_1.txt"))
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_bulk_actor_opts_2.txt"))
    end
  end

  describe "update with :file argument" do
    test "attaches file on update" do
      post =
        AshStorage.Test.Post
        |> Ash.Changeset.for_create(:create, %{title: "plain post"})
        |> Ash.create!()

      path = Path.join(System.tmp_dir!(), "ash_storage_update_test.jpg")
      File.write!(path, "image bytes")

      post =
        post
        |> Ash.Changeset.for_update(:update_cover_image, %{
          cover_image: Ash.Type.File.from_path(path)
        })
        |> Ash.update!()

      post = Ash.load!(post, cover_image: :blob)
      assert post.cover_image.blob.filename
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_update_test.jpg"))
    end

    test "replaces existing attachment on update" do
      path1 = Path.join(System.tmp_dir!(), "ash_storage_old.txt")
      path2 = Path.join(System.tmp_dir!(), "ash_storage_new.txt")
      File.write!(path1, "old content")
      File.write!(path2, "new content")

      post =
        AshStorage.Test.Post
        |> Ash.Changeset.for_create(:create_with_image, %{
          title: "will replace",
          cover_image: Ash.Type.File.from_path(path1)
        })
        |> Ash.create!()

      post = Ash.load!(post, cover_image: :blob)
      old_key = post.cover_image.blob.key

      post =
        post
        |> Ash.Changeset.for_update(:update_cover_image, %{
          cover_image: Ash.Type.File.from_path(path2)
        })
        |> Ash.update!()

      post = Ash.load!(post, cover_image: :blob)
      assert post.cover_image.blob.filename

      assert {:ok, "new content"} =
               AshStorage.Service.Test.download(post.cover_image.blob.key, [])

      refute AshStorage.Service.Test.exists?(old_key)
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_old.txt"))
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_new.txt"))
    end
  end

  describe "caller context contract" do
    test "HandleFileArgument authorizes nested blob and attachment creates with the caller actor" do
      path = Path.join(System.tmp_dir!(), "ash_storage_policy_create.txt")
      File.write!(path, "policy create")

      assert {:ok, post} =
               AshStorage.Test.PolicyRequiredPost
               |> Ash.Changeset.for_create(
                 :create_with_image,
                 %{
                   title: "policy protected",
                   cover_image: Ash.Type.File.from_path(path)
                 },
                 actor: :authorized
               )
               |> Ash.create()

      post = Ash.load!(post, [cover_image: :blob], actor: :authorized)
      assert post.cover_image.blob.filename == "ash_storage_policy_create.txt"
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_policy_create.txt"))
    end

    test "HandleFileArgument authorizes replace reads and destroys with the caller actor" do
      old_path = Path.join(System.tmp_dir!(), "ash_storage_policy_old.txt")
      new_path = Path.join(System.tmp_dir!(), "ash_storage_policy_new.txt")
      File.write!(old_path, "old policy content")
      File.write!(new_path, "new policy content")

      post =
        AshStorage.Test.PolicyRequiredPost
        |> Ash.Changeset.for_create(
          :create_with_image,
          %{
            title: "policy replacement",
            cover_image: Ash.Type.File.from_path(old_path)
          },
          actor: :authorized
        )
        |> Ash.create!()

      post = Ash.load!(post, [cover_image: :blob], actor: :authorized)
      old_key = post.cover_image.blob.key

      assert {:ok, replaced} =
               post
               |> Ash.Changeset.for_update(
                 :replace_image,
                 %{cover_image: Ash.Type.File.from_path(new_path)},
                 actor: :authorized
               )
               |> Ash.update()

      replaced = Ash.load!(replaced, [cover_image: :blob], actor: :authorized)
      assert replaced.cover_image.blob.filename == "ash_storage_policy_new.txt"
      refute AshStorage.Service.Test.exists?(old_key)
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_policy_old.txt"))
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_policy_new.txt"))
    end

    test "replacement keeps the previous object when the transaction rolls back" do
      old_path = Path.join(System.tmp_dir!(), "ash_storage_rollback_old.txt")
      new_path = Path.join(System.tmp_dir!(), "ash_storage_rollback_new.txt")
      File.write!(old_path, "old rollback content")
      File.write!(new_path, "new rollback content")

      post =
        AshStorage.Test.PolicyRequiredPost
        |> Ash.Changeset.for_create(
          :create_with_image,
          %{
            title: "rollback replacement",
            cover_image: Ash.Type.File.from_path(old_path)
          },
          actor: :authorized
        )
        |> Ash.create!()
        |> Ash.load!([cover_image: :blob], actor: :authorized)

      old_key = post.cover_image.blob.key
      assert AshStorage.Service.Test.exists?(old_key)
      keys_before = AshStorage.Service.Test.list_keys()

      assert {:error, _} =
               post
               |> Ash.Changeset.for_update(
                 :replace_image_then_fail,
                 %{cover_image: Ash.Type.File.from_path(new_path)},
                 actor: :authorized
               )
               |> Ash.update()

      assert AshStorage.Service.Test.exists?(old_key)
      assert AshStorage.Service.Test.list_keys() == keys_before
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_rollback_old.txt"))
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_rollback_new.txt"))
    end

    test "failed PostgreSQL replacement rolls back rows and the next retry succeeds" do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(AshStorage.TestRepo)

      old_path = Path.join(System.tmp_dir!(), "ash_storage_pg_rollback_old.txt")
      new_path = Path.join(System.tmp_dir!(), "ash_storage_pg_rollback_new.txt")
      File.write!(old_path, "old pg rollback content")
      File.write!(new_path, "new pg rollback content")

      post =
        AshStorage.Test.RestrictFkTestPost
        |> Ash.Changeset.for_create(:create, %{title: "pg rollback replacement"})
        |> Ash.create!()

      assert {:ok, %{blob: old_blob}} =
               AshStorage.Operations.attach(post, :cover_image, "old pg rollback content",
                 filename: "ash_storage_pg_rollback_old.txt"
               )

      keys_before = AshStorage.Service.Test.list_keys()

      assert {:error, _} =
               post
               |> Ash.Changeset.for_update(:replace_image_then_fail, %{
                 cover_image: Ash.Type.File.from_path(new_path)
               })
               |> Ash.update()

      assert AshStorage.Service.Test.list_keys() == keys_before

      persisted = Ash.load!(post, cover_image: :blob)
      assert persisted.cover_image.blob.key == old_blob.key

      assert {:ok, replaced} =
               persisted
               |> Ash.Changeset.for_update(:replace_image, %{
                 cover_image: Ash.Type.File.from_path(new_path)
               })
               |> Ash.update()

      replaced = Ash.load!(replaced, cover_image: :blob)
      refute replaced.cover_image.blob.key == old_blob.key
      refute AshStorage.Service.Test.exists?(old_blob.key)
      assert AshStorage.Service.Test.exists?(replaced.cover_image.blob.key)
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_pg_rollback_old.txt"))
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_pg_rollback_new.txt"))
    end
  end

  describe "end-to-end with URL" do
    test "create, load attachment URL" do
      path = Path.join(System.tmp_dir!(), "ash_storage_url_test.png")
      File.write!(path, "png data")

      post =
        AshStorage.Test.Post
        |> Ash.Changeset.for_create(:create_with_image, %{
          title: "url test",
          cover_image: Ash.Type.File.from_path(path)
        })
        |> Ash.create!()

      post = Ash.load!(post, :cover_image_url)
      assert post.cover_image_url =~ "http://test.local/storage/"
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_url_test.png"))
    end
  end
end
