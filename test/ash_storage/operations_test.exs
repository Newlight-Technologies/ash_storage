defmodule AshStorage.OperationsTest do
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

  describe "private caller context" do
    test "only the AshOban marker and shared scope cross the child boundary" do
      callback_context = %Ash.Resource.Change.Context{
        actor: nil,
        tenant: "tenant-a",
        authorize?: true,
        tracer: :tracer,
        source_context: %{
          shared: %{locale: "en"},
          private: %{ash_oban?: true, secret: :parent_only},
          accessing_from: %{resource: :parent},
          data_layer: %{tenant: "wrong"},
          arbitrary: :parent_only
        }
      }

      assert AshStorage.ChildContext.to_opts(callback_context) == [
               actor: nil,
               tenant: "tenant-a",
               context: %{shared: %{locale: "en"}, private: %{ash_oban?: true}},
               tracer: :tracer,
               authorize?: true
             ]

      for value <- [nil, false, "true", 1] do
        refute get_in(
                 AshStorage.ChildContext.to_opts(%{
                   callback_context
                   | source_context: %{private: %{ash_oban?: value}}
                 }),
                 [:context, :private, :ash_oban?]
               )
      end

      assert AshStorage.ChildContext.narrow_opts(
               scope: %{
                 actor: %{role: :storage},
                 tenant: "scope-tenant",
                 context: %{shared: %{timezone: "UTC", preferences: %{time: :hour24}}}
               },
               context: %{
                 shared: %{locale: "en", preferences: %{language: "en"}},
                 private: %{ash_oban?: true, secret: :parent_only},
                 accessing_from: :parent,
                 data_layer: :parent
               },
               data_layer: :parent,
               arbitrary: :parent_only
             )
             |> Map.new() == %{
               actor: %{role: :storage},
               tenant: "scope-tenant",
               context: %{
                 shared: %{
                   timezone: "UTC",
                   locale: "en",
                   preferences: %{time: :hour24, language: "en"}
                 },
                 private: %{ash_oban?: true}
               }
             }
    end

    test "nil-actor AshOban context reaches blob and attachment creates and replacement reads" do
      post =
        AshStorage.Test.ContextPolicyPost
        |> Ash.Changeset.for_create(:create, %{title: "private attach"})
        |> Ash.create!()

      opts = [actor: nil, authorize?: true, context: %{private: %{ash_oban?: true}}]

      assert {:ok, %{blob: first_blob, attachment: first_attachment}} =
               Operations.attach(post, :cover_image, "first", [filename: "first.txt"] ++ opts)

      assert first_attachment.blob_id == first_blob.id
      assert AshStorage.Service.Test.exists?(first_blob.key)

      assert {:ok, %{blob: replacement_blob, attachment: replacement_attachment}} =
               Operations.attach(
                 post,
                 :cover_image,
                 "replacement",
                 [filename: "next.txt"] ++ opts
               )

      assert replacement_attachment.blob_id == replacement_blob.id
      assert replacement_attachment.id != first_attachment.id
      refute AshStorage.Service.Test.exists?(first_blob.key)
      assert AshStorage.Service.Test.exists?(replacement_blob.key)

      loaded =
        Ash.load!(post, [cover_image: :blob],
          actor: %{role: :storage, visible_name: "cover_image"}
        )

      assert loaded.cover_image.id == replacement_attachment.id
      assert loaded.cover_image.blob.id == replacement_blob.id
    end

    test "nil actor without authorized private context cannot attach" do
      post =
        AshStorage.Test.ContextPolicyPost
        |> Ash.Changeset.for_create(:create, %{title: "denied attach"})
        |> Ash.create!()

      keys_before = AshStorage.Service.Test.list_keys()

      for context <- [%{}, %{private: %{ash_oban?: false}}, %{private: %{other: true}}] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Operations.attach(post, :cover_image, "denied",
                   filename: "denied.txt",
                   actor: nil,
                   authorize?: true,
                   context: context
                 )
      end

      assert AshStorage.Service.Test.list_keys() == keys_before

      assert Ash.load!(post, :cover_image, actor: %{role: :storage, visible_name: "cover_image"}).cover_image ==
               nil
    end

    test "allowed parent and blob cannot bypass forbidden attachment create" do
      post =
        AshStorage.Test.ContextPolicyPost
        |> Ash.Changeset.for_create(:create, %{title: "child create denied"})
        |> Ash.create!()

      keys_before = AshStorage.Service.Test.list_keys()

      assert {:error, %Ash.Error.Forbidden{}} =
               Operations.attach(post, :cover_image, "rejected",
                 filename: "rejected.txt",
                 actor: %{role: :other},
                 authorize?: true
               )

      assert AshStorage.Service.Test.list_keys() == keys_before

      assert Ash.load!(post, :cover_image, actor: %{role: :storage, visible_name: "cover_image"}).cover_image ==
               nil
    end

    test "filtered replacement read raises Forbidden and keeps the old attachment and object" do
      post =
        AshStorage.Test.ContextPolicyPost
        |> Ash.Changeset.for_create(:create, %{title: "replacement denied"})
        |> Ash.create!()

      marker_opts = [actor: nil, authorize?: true, context: %{private: %{ash_oban?: true}}]

      assert {:ok, %{blob: old_blob, attachment: old_attachment}} =
               Operations.attach(post, :cover_image, "old", [filename: "old.txt"] ++ marker_opts)

      assert {:error, %Ash.Error.Forbidden{}} =
               Operations.attach(post, :cover_image, "new",
                 filename: "new.txt",
                 actor: %{role: :create_only, visible_name: "documents"},
                 authorize?: true
               )

      assert AshStorage.Service.Test.list_keys() == [old_blob.key]

      current =
        Ash.load!(post, [cover_image: :blob],
          actor: %{role: :storage, visible_name: "cover_image"}
        )

      assert current.cover_image.id == old_attachment.id
      assert current.cover_image.blob.id == old_blob.id
    end

    test "dangling blob on replacement fails closed without repairing or deleting the object" do
      post =
        AshStorage.Test.ContextPolicyPost
        |> Ash.Changeset.for_create(:create, %{title: "dangling blob"})
        |> Ash.create!()

      actor = %{role: :storage, visible_name: "cover_image"}

      assert {:ok, %{blob: old_blob, attachment: old_attachment}} =
               Operations.attach(post, :cover_image, "old",
                 filename: "old.txt",
                 actor: actor,
                 authorize?: true
               )

      assert :ok = Ash.destroy(old_blob, actor: actor, authorize?: true)
      assert AshStorage.Service.Test.exists?(old_blob.key)

      assert {:error, _} =
               Operations.attach(post, :cover_image, "new",
                 filename: "new.txt",
                 actor: actor,
                 authorize?: true
               )

      assert AshStorage.Service.Test.list_keys() == [old_blob.key]

      assert {:ok, _} =
               Ash.get(AshStorage.Test.ContextPolicyAttachment, old_attachment.id,
                 actor: actor,
                 authorize?: true
               )
    end

    test "filtered blob on replacement fails closed without deleting the hidden object" do
      post =
        AshStorage.Test.ContextPolicyPost
        |> Ash.Changeset.for_create(:create, %{title: "hidden blob"})
        |> Ash.create!()

      actor = %{role: :storage, visible_name: "cover_image"}

      assert {:ok, %{blob: old_blob, attachment: old_attachment}} =
               Operations.attach(post, :cover_image, "old",
                 filename: "hidden.txt",
                 actor: actor,
                 authorize?: true
               )

      assert {:error, _} =
               Operations.attach(post, :cover_image, "new",
                 filename: "new.txt",
                 actor: actor,
                 authorize?: true
               )

      assert AshStorage.Service.Test.list_keys() == [old_blob.key]

      assert {:ok, _} =
               Ash.get(AshStorage.Test.ContextPolicyAttachment, old_attachment.id,
                 actor: actor,
                 authorize?: true
               )
    end

    test "forbidden child destroy during purge leaves object and rows intact" do
      post =
        AshStorage.Test.ContextPolicyPost
        |> Ash.Changeset.for_create(:create, %{title: "purge denied"})
        |> Ash.create!()

      assert {:ok, %{blob: blob, attachment: attachment}} =
               Operations.attach(post, :cover_image, "kept",
                 filename: "kept.txt",
                 actor: %{role: :storage, visible_name: "cover_image"},
                 authorize?: true
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               Operations.purge(post, :cover_image,
                 actor: %{role: :read_only, visible_name: "cover_image"},
                 authorize?: true
               )

      assert AshStorage.Service.Test.exists?(blob.key)

      current =
        Ash.load!(post, [cover_image: :blob],
          actor: %{role: :storage, visible_name: "cover_image"}
        )

      assert current.cover_image.id == attachment.id
      assert current.cover_image.blob.id == blob.id
    end

    test "nil-actor AshOban context reaches detach and purge child destroys" do
      post =
        AshStorage.Test.ContextPolicyPost
        |> Ash.Changeset.for_create(:create, %{title: "detach and purge"})
        |> Ash.create!()

      opts = [actor: nil, authorize?: true, context: %{private: %{ash_oban?: true}}]

      assert {:ok, %{blob: detached_blob}} =
               Operations.attach(post, :cover_image, "detached", [filename: "old.txt"] ++ opts)

      assert {:ok, [_]} = Operations.detach(post, :cover_image, opts)
      assert AshStorage.Service.Test.exists?(detached_blob.key)

      assert {:ok, %{blob: purged_blob}} =
               Operations.attach(post, :cover_image, "purged", [filename: "new.txt"] ++ opts)

      assert {:ok, [_]} = Operations.purge(post, :cover_image, opts)
      refute AshStorage.Service.Test.exists?(purged_blob.key)
    end

    test "AttachBlob preserves AshOban marker through preexisting blob and child creation" do
      post =
        AshStorage.Test.ContextPolicyPost
        |> Ash.Changeset.for_create(:create, %{title: "attach staged"})
        |> Ash.create!()

      opts = [actor: nil, authorize?: true, context: %{private: %{ash_oban?: true}}]

      assert {:ok, %{blob: blob}} =
               Operations.prepare_direct_upload(
                 AshStorage.Test.ContextPolicyPost,
                 :cover_image,
                 [filename: "staged.txt"] ++ opts
               )

      :ok =
        AshStorage.Service.Test.upload(blob.key, "staged", AshStorage.Service.Context.new([]))

      assert {:ok, updated} =
               post
               |> Ash.Changeset.for_update(:attach_blob, %{cover_image_blob_id: blob.id}, opts)
               |> Ash.update(opts)

      loaded =
        Ash.load!(updated, [cover_image: :blob],
          actor: %{role: :storage, visible_name: "cover_image"}
        )

      assert loaded.cover_image.blob.id == blob.id
    end

    test "AttachFile preserves AshOban marker when creating a host and its children" do
      path = Path.join(System.tmp_dir!(), "ash_storage_context_attach_file.txt")
      File.write!(path, "file argument")
      opts = [actor: nil, authorize?: true, context: %{private: %{ash_oban?: true}}]

      assert {:ok, post} =
               AshStorage.Test.ContextPolicyPost
               |> Ash.Changeset.for_create(
                 :create_with_file,
                 %{title: "attach file", cover_image: Ash.Type.File.from_path(path)},
                 opts
               )
               |> Ash.create(opts)

      loaded =
        Ash.load!(post, [cover_image: :blob],
          actor: %{role: :storage, visible_name: "cover_image"}
        )

      assert loaded.cover_image.blob.filename == "ash_storage_context_attach_file.txt"
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_context_attach_file.txt"))
    end

    test "HandleFileArgument preserves AshOban marker through create and replacement" do
      path = Path.join(System.tmp_dir!(), "ash_storage_context_native_file.txt")
      replacement_path = Path.join(System.tmp_dir!(), "ash_storage_context_replacement_file.txt")
      File.write!(path, "native file argument")
      File.write!(replacement_path, "replacement file argument")
      opts = [actor: nil, authorize?: true, context: %{private: %{ash_oban?: true}}]

      assert {:ok, post} =
               AshStorage.Test.ContextPolicyPost
               |> Ash.Changeset.for_create(
                 :create_with_image,
                 %{title: "native file", cover_image: Ash.Type.File.from_path(path)},
                 opts
               )
               |> Ash.create(opts)

      loaded =
        Ash.load!(post, [cover_image: :blob],
          actor: %{role: :storage, visible_name: "cover_image"}
        )

      assert loaded.cover_image.blob.filename == "ash_storage_context_native_file.txt"

      old_key = loaded.cover_image.blob.key

      assert {:ok, replaced} =
               post
               |> Ash.Changeset.for_update(
                 :replace_image,
                 %{cover_image: Ash.Type.File.from_path(replacement_path)},
                 opts
               )
               |> Ash.update(opts)

      replaced =
        Ash.load!(replaced, [cover_image: :blob],
          actor: %{role: :storage, visible_name: "cover_image"}
        )

      assert replaced.cover_image.blob.filename == "ash_storage_context_replacement_file.txt"
      refute AshStorage.Service.Test.exists?(old_key)
      assert AshStorage.Service.Test.exists?(replaced.cover_image.blob.key)
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_context_native_file.txt"))
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_context_replacement_file.txt"))
    end

    test "PurgeFile preserves AshOban marker when destroying a staged blob" do
      post =
        AshStorage.Test.ContextPolicyPost
        |> Ash.Changeset.for_create(:create, %{title: "purge blob"})
        |> Ash.create!()

      opts = [actor: nil, authorize?: true, context: %{private: %{ash_oban?: true}}]

      assert {:ok, %{blob: blob}} =
               Operations.attach(post, :cover_image, "purge me", [filename: "purge.txt"] ++ opts)

      assert {:ok, [_]} = Operations.detach(post, :cover_image, opts)
      assert :ok = Ash.destroy(blob, Keyword.put(opts, :action, :purge_blob))
      refute AshStorage.Service.Test.exists?(blob.key)
    end

    test "AttachFile batch callback forwards AshOban marker to both children" do
      path1 = Path.join(System.tmp_dir!(), "ash_storage_context_bulk_1.txt")
      path2 = Path.join(System.tmp_dir!(), "ash_storage_context_bulk_2.txt")
      File.write!(path1, "bulk one")
      File.write!(path2, "bulk two")

      result =
        Ash.bulk_create(
          [
            %{title: "bulk one", cover_image: Ash.Type.File.from_path(path1)},
            %{title: "bulk two", cover_image: Ash.Type.File.from_path(path2)}
          ],
          AshStorage.Test.ContextPolicyPost,
          :create_with_file,
          actor: nil,
          authorize?: true,
          context: %{private: %{ash_oban?: true}},
          return_records?: true,
          return_errors?: true
        )

      assert result.status == :success

      filenames =
        result.records
        |> Ash.load!([cover_image: :blob],
          actor: %{role: :storage, visible_name: "cover_image"}
        )
        |> Enum.map(& &1.cover_image.blob.filename)
        |> MapSet.new()

      assert filenames ==
               MapSet.new([
                 "ash_storage_context_bulk_1.txt",
                 "ash_storage_context_bulk_2.txt"
               ])
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_context_bulk_1.txt"))
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_context_bulk_2.txt"))
    end
  end

  describe "attach/4" do
    test "uploads file and creates blob + attachment" do
      post = create_post!()

      assert {:ok, %{blob: blob, attachment: attachment}} =
               Operations.attach(post, :cover_image, "hello world",
                 filename: "hello.txt",
                 content_type: "text/plain"
               )

      assert blob.filename == "hello.txt"
      assert blob.content_type == "text/plain"
      assert blob.byte_size == 11
      assert blob.checksum == Base.encode64(:crypto.hash(:md5, "hello world"))
      assert blob.service_name == AshStorage.Service.Test

      assert attachment.name == "cover_image"
      assert attachment.blob_id == blob.id

      # File is in the service
      assert AshStorage.Service.Test.exists?(blob.key)
      assert {:ok, "hello world"} = AshStorage.Service.Test.download(blob.key, [])
    end

    test "accepts Ash.Type.File" do
      post = create_post!()
      path = Path.join(System.tmp_dir!(), "ash_storage_test_file.txt")
      File.write!(path, "file type data")

      file = Ash.Type.File.from_path(path)

      {:ok, %{blob: blob}} =
        Operations.attach(post, :cover_image, file,
          filename: "from_file_type.txt",
          content_type: "text/plain"
        )

      assert blob.filename == "from_file_type.txt"
      assert {:ok, "file type data"} = AshStorage.Service.Test.download(blob.key, [])
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_test_file.txt"))
    end

    test "accepts %Plug.Upload{} and uploads the file bytes (not the path string)" do
      # Regression: before the dedicated `read_io/1` clause, the struct's
      # `:path` was a binary that matched the generic `is_binary/1` clause
      # and the literal path string was uploaded as the blob body.
      post = create_post!()
      path = Path.join(System.tmp_dir!(), "ash_storage_plug_upload_test.bin")
      contents = "actual file bytes via Plug.Upload"
      File.write!(path, contents)

      upload = %Plug.Upload{
        path: path,
        filename: "via-plug.bin",
        content_type: "application/octet-stream"
      }

      {:ok, %{blob: blob}} =
        Operations.attach(post, :cover_image, upload,
          filename: upload.filename,
          content_type: upload.content_type
        )

      # Bytes stored = file contents, NOT the path string. byte_size is the
      # most economical proof — a regression would store the ~50-char path.
      assert blob.byte_size == byte_size(contents)
      assert {:ok, ^contents} = AshStorage.Service.Test.download(blob.key, [])
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_plug_upload_test.bin"))
    end

    test "replaces existing has_one_attached" do
      post = create_post!()

      {:ok, %{blob: old_blob}} =
        Operations.attach(post, :cover_image, "old file",
          filename: "old.txt",
          content_type: "text/plain"
        )

      {:ok, %{blob: new_blob}} =
        Operations.attach(post, :cover_image, "new file",
          filename: "new.txt",
          content_type: "text/plain"
        )

      # Old file is purged
      refute AshStorage.Service.Test.exists?(old_blob.key)
      # New file exists
      assert AshStorage.Service.Test.exists?(new_blob.key)
      assert {:ok, "new file"} = AshStorage.Service.Test.download(new_blob.key, [])
    end

    test "removes a newly uploaded object when the attach transaction rolls back" do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(AshStorage.TestRepo)

      post =
        AshStorage.Test.PgPost
        |> Ash.Changeset.for_create(:create, %{title: "failed attach"})
        |> Ash.create!()

      keys_before = AshStorage.Service.Test.list_keys()

      assert {:error, _} =
               post
               |> Ash.Changeset.for_update(:attach_cover_image_then_fail, %{
                 io: "orphan candidate",
                 filename: "rollback.txt",
                 content_type: "text/plain"
               })
               |> Ash.update()

      assert AshStorage.Service.Test.list_keys() == keys_before
      assert Ash.load!(post, :cover_image).cover_image == nil
    end

    test "appends to has_many_attached" do
      post = create_post!()

      {:ok, %{blob: blob1}} =
        Operations.attach(post, :documents, "doc one",
          filename: "doc1.txt",
          content_type: "text/plain"
        )

      {:ok, %{blob: blob2}} =
        Operations.attach(post, :documents, "doc two",
          filename: "doc2.txt",
          content_type: "text/plain"
        )

      # Both files exist
      assert AshStorage.Service.Test.exists?(blob1.key)
      assert AshStorage.Service.Test.exists?(blob2.key)
    end

    test "stores custom metadata on blob" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        Operations.attach(post, :cover_image, "data",
          filename: "photo.jpg",
          metadata: %{"width" => 100, "height" => 200}
        )

      assert blob.metadata == %{"width" => 100, "height" => 200}
    end

    test "handles iodata input" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        Operations.attach(post, :cover_image, ["hello", " ", "world"], filename: "hello.txt")

      assert blob.byte_size == 11
      assert {:ok, "hello world"} = AshStorage.Service.Test.download(blob.key, [])
    end

    test "returns error for unknown attachment name" do
      post = create_post!()

      assert_raise ArgumentError, fn ->
        Operations.attach(post, :nonexistent, "data", filename: "f.txt")
      end
    end
  end

  describe "detach/3" do
    test "detaches has_one_attached without deleting file" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        Operations.attach(post, :cover_image, "data", filename: "f.txt")

      assert {:ok, [_]} = Operations.detach(post, :cover_image)

      # File still exists in storage
      assert AshStorage.Service.Test.exists?(blob.key)
    end

    test "detaches specific blob from has_many_attached" do
      post = create_post!()

      {:ok, %{blob: blob1}} =
        Operations.attach(post, :documents, "doc1", filename: "d1.txt")

      {:ok, %{blob: blob2}} =
        Operations.attach(post, :documents, "doc2", filename: "d2.txt")

      assert {:ok, [_]} = Operations.detach(post, :documents, blob_id: blob1.id)

      # Both files still in storage
      assert AshStorage.Service.Test.exists?(blob1.key)
      assert AshStorage.Service.Test.exists?(blob2.key)
    end

    test "returns error when blob_id missing for has_many" do
      post = create_post!()
      Operations.attach(post, :documents, "doc", filename: "d.txt")

      assert {:error, %Ash.Error.Unknown{}} = Operations.detach(post, :documents)
    end
  end

  describe "purge/3" do
    test "purges has_one_attached: removes attachment, blob, and file" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        Operations.attach(post, :cover_image, "data", filename: "f.txt")

      assert {:ok, [_]} = Operations.purge(post, :cover_image)

      refute AshStorage.Service.Test.exists?(blob.key)
    end

    test "purges specific blob from has_many_attached" do
      post = create_post!()

      {:ok, %{blob: blob1}} =
        Operations.attach(post, :documents, "doc1", filename: "d1.txt")

      {:ok, %{blob: blob2}} =
        Operations.attach(post, :documents, "doc2", filename: "d2.txt")

      assert {:ok, [_]} = Operations.purge(post, :documents, blob_id: blob1.id)

      refute AshStorage.Service.Test.exists?(blob1.key)
      assert AshStorage.Service.Test.exists?(blob2.key)
    end

    test "purges all has_many_attached with :all option" do
      post = create_post!()

      {:ok, %{blob: blob1}} =
        Operations.attach(post, :documents, "doc1", filename: "d1.txt")

      {:ok, %{blob: blob2}} =
        Operations.attach(post, :documents, "doc2", filename: "d2.txt")

      assert {:ok, purged} = Operations.purge(post, :documents, all: true)
      assert length(purged) == 2

      refute AshStorage.Service.Test.exists?(blob1.key)
      refute AshStorage.Service.Test.exists?(blob2.key)
    end

    test "returns error when blob_id missing for has_many" do
      post = create_post!()
      Operations.attach(post, :documents, "doc", filename: "d.txt")

      assert {:error, %Ash.Error.Unknown{}} = Operations.purge(post, :documents)
    end
  end
end
