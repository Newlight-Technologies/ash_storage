defmodule AshStorage.TransactionTest do
  use ExUnit.Case, async: false

  alias AshStorage.{Operations, TestRepo}
  alias AshStorage.Test.{RestrictFkTestPost, RestrictFkTestBlob, RestrictFkTestAttachment}

  @resources [RestrictFkTestPost, RestrictFkTestBlob, RestrictFkTestAttachment]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    AshStorage.Service.Test.reset!()

    post =
      RestrictFkTestPost
      |> Ash.Changeset.for_create(:create, %{title: "outer transaction"})
      |> Ash.create!()

    {:ok, %{blob: blob}} =
      Operations.attach(post, :cover_image, "original", filename: "original.txt")

    %{post: post, old_key: blob.key, keys: AshStorage.Service.Test.list_keys()}
  end

  test "late outer failure removes new upload and preserves replaced file and rows", context do
    assert {:error, _} =
             Operations.transact(@resources, fn ->
               {:ok, %{blob: replacement}} =
                 Operations.attach(context.post, :cover_image, "new", filename: "new.txt")

               assert AshStorage.Service.Test.exists?(replacement.key)
               assert AshStorage.Service.Test.exists?(context.old_key)
               {:error, "later promotion step failed"}
             end)

    assert AshStorage.Service.Test.list_keys() == context.keys
    assert Ash.load!(context.post, cover_image: :blob).cover_image.blob.key == context.old_key
  end

  test "commit preserves replacement and only then removes original", context do
    assert {:ok, new_key} =
             Operations.transact(@resources, fn ->
               {:ok, %{blob: replacement}} =
                 Operations.attach(context.post, :cover_image, "new", filename: "new.txt")

               assert AshStorage.Service.Test.exists?(context.old_key)
               replacement.key
             end)

    refute AshStorage.Service.Test.exists?(context.old_key)
    assert AshStorage.Service.Test.exists?(new_key)
    assert Ash.load!(context.post, cover_image: :blob).cover_image.blob.key == new_key
  end

  test "exception inside transaction rolls back uploads without deleting original", context do
    assert_raise RuntimeError, "inside transaction", fn ->
      Operations.transact(@resources, fn ->
        {:ok, _} = Operations.attach(context.post, :cover_image, "new", filename: "new.txt")
        raise "inside transaction"
      end)
    end

    assert AshStorage.Service.Test.list_keys() == context.keys
    assert Ash.load!(context.post, cover_image: :blob).cover_image.blob.key == context.old_key
  end

  test "post-commit notification failure does not delete committed replacement", context do
    Process.put({AshStorage.Test.TransactionTestNotifier, :raise?}, true)

    assert_raise RuntimeError, "post-commit notification failed", fn ->
      Operations.transact(@resources, fn ->
        {:ok, _} = Operations.attach(context.post, :cover_image, "new", filename: "new.txt")
        :done
      end)
    end

    persisted = Ash.load!(context.post, cover_image: :blob)
    refute persisted.cover_image.blob.key == context.old_key
    assert AshStorage.Service.Test.exists?(persisted.cover_image.blob.key)
    refute AshStorage.Service.Test.exists?(context.old_key)
  end

  test "caller may receive committed notifications", context do
    assert {:ok, :done, notifications} =
             Operations.transact(
               @resources,
               fn ->
                 {:ok, _} =
                   Operations.attach(context.post, :cover_image, "new", filename: "new.txt")

                 :done
               end, return_notifications?: true)

    assert notifications != []
    assert [] == Ash.Notifier.notify(notifications)
  end

  test "does not pretend to own an already open transaction" do
    assert {:ok, :checked} =
             Ash.transact(@resources, fn ->
               assert_raise ArgumentError, ~r/must own the outer transaction/, fn ->
                 Operations.transact(@resources, fn -> flunk("must not run") end)
               end

               :checked
             end)
  end

  test "file-argument upload also survives only a committed outer transaction", context do
    path = Path.join(System.tmp_dir!(), "storage-outer-#{System.unique_integer([:positive])}.txt")
    File.write!(path, "file argument")

    try do
      assert {:error, _} =
               Operations.transact(@resources, fn ->
                 context.post
                 |> Ash.Changeset.for_update(:replace_image, %{
                   cover_image: Ash.Type.File.from_path(path)
                 })
                 |> Ash.update!()

                 {:error, "late failure"}
               end)

      assert AshStorage.Service.Test.list_keys() == context.keys
      assert Ash.load!(context.post, cover_image: :blob).cover_image.blob.key == context.old_key
    after
      File.rm(path)
    end
  end
end
