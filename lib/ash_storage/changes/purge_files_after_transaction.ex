defmodule AshStorage.Changes.PurgeFilesAfterTransaction do
  @moduledoc false

  require Logger

  @success_context_key :__ash_storage_keys_to_purge__

  def put_changeset(changeset, keys_to_purge) do
    append_changeset_context(changeset, @success_context_key, keys_to_purge)
  end

  def put_record(record, keys_to_purge) do
    existing = record.__metadata__[@success_context_key] || []
    Ash.Resource.put_metadata(record, @success_context_key, existing ++ keys_to_purge)
  end

  def run(changeset, {:ok, record}) do
    keys_to_purge =
      changeset.context[@success_context_key] || record.__metadata__[@success_context_key] || []

    case purge(keys_to_purge) do
      [] ->
        {:ok, record}

      failures ->
        {:error,
         "Storage transaction committed, but object cleanup failed; reconciliation required: #{inspect(failures)}"}
    end
  end

  def run(_changeset, {:error, error}), do: {:error, error}

  def with_rollback_tracking(changeset, callback, rollback_ref) do
    Process.put(rollback_ref, [])

    try do
      callback.(changeset)
    after
      Process.delete(rollback_ref)
    end
  end

  def track_rollback(rollback_ref, uploaded_file) do
    Process.put(rollback_ref, [uploaded_file | Process.get(rollback_ref, [])])
  end

  def cleanup_rollback(rollback_ref, {:error, _error} = result) do
    failures = purge(Process.get(rollback_ref, []))

    if failures != [] do
      Logger.error(
        "Storage transaction rolled back, but uploaded object cleanup failed; " <>
          "reconciliation required: #{inspect(failures)}"
      )
    end

    result
  end

  def cleanup_rollback(_rollback_ref, {:ok, _record} = result), do: result

  def purge_now(keys_to_purge), do: purge(keys_to_purge)

  defp append_changeset_context(changeset, key, values) do
    existing = changeset.context[key] || []
    Ash.Changeset.put_context(changeset, key, existing ++ values)
  end

  defp purge(keys_to_purge) do
    Enum.flat_map(keys_to_purge, fn {service_mod, ctx, key} ->
      case safe_delete(service_mod, ctx, key) do
        :ok -> []
        {:error, reason} -> [%{service: service_mod, key: key, reason: reason}]
      end
    end)
  end

  defp safe_delete(service_mod, ctx, key) do
    AshStorage.Operations.delete_from_service(service_mod, ctx, key)
  rescue
    error -> {:error, Exception.format(:error, error, __STACKTRACE__)}
  catch
    kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
  end
end
