defmodule AshStorage.BlobResource.Changes.PurgeFile do
  @moduledoc """
  A change that deletes the file from storage when a blob is destroyed.

  This is used by the `:purge_blob` action on blob resources. It loads
  the `parsed_service_opts` calculation to reconstitute the service options
  from the stored map, destroys the database row inside the transaction, and
  deletes the file only after the transaction succeeds.
  """
  use Ash.Resource.Change

  @context_key :__ash_storage_file_to_purge__

  @impl true
  def change(changeset, _opts, context) do
    context_opts = Ash.Context.to_opts(context)

    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      blob = Ash.load!(changeset.data, :parsed_service_opts, context_opts)

      service_context =
        AshStorage.Service.Context.new(blob.parsed_service_opts || [],
          actor: Keyword.get(context_opts, :actor),
          tenant: Keyword.get(context_opts, :tenant)
        )

      Ash.Changeset.put_context(
        changeset,
        @context_key,
        {blob.service_name, service_context, blob.key}
      )
    end)
    |> Ash.Changeset.after_transaction(&delete_file/2)
  end

  @impl true
  def atomic(changeset, opts, context) do
    {:ok, change(changeset, opts, context)}
  end

  defp delete_file(changeset, {:ok, record}) do
    {service_mod, service_context, key} = changeset.context[@context_key]

    case service_mod.delete(key, service_context) do
      :ok -> {:ok, record}
      {:error, reason} -> {:error, "Failed to delete file from storage: #{inspect(reason)}"}
    end
  end

  defp delete_file(_changeset, {:error, error}), do: {:error, error}
end
