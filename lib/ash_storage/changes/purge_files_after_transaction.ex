defmodule AshStorage.Changes.PurgeFilesAfterTransaction do
  @moduledoc false

  @context_key :__ash_storage_keys_to_purge__

  def put_changeset(changeset, keys_to_purge) do
    Ash.Changeset.put_context(changeset, @context_key, keys_to_purge)
  end

  def put_record(record, keys_to_purge) do
    Ash.Resource.put_metadata(record, @context_key, keys_to_purge)
  end

  def run(changeset, {:ok, record}) do
    keys_to_purge =
      changeset.context[@context_key] || record.__metadata__[@context_key] || []

    Enum.each(keys_to_purge, fn {service_mod, ctx, key} ->
      AshStorage.Operations.delete_from_service(service_mod, ctx, key)
    end)

    {:ok, record}
  end

  def run(_changeset, {:error, error}), do: {:error, error}
end
