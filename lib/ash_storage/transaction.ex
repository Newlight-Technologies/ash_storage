defmodule AshStorage.Transaction do
  @moduledoc false
  require Logger

  alias AshStorage.Changes.PurgeFilesAfterTransaction

  @key {__MODULE__, :state}

  def run(resources, callback, opts) do
    resources = List.wrap(resources)

    if resources == [] or not is_nil(Process.get(@key)) or
         Process.get(:ash_started_transaction?) == true or
         Enum.any?(resources, fn resource ->
           not Ash.DataLayer.can?(:transact, resource) or Ash.DataLayer.in_transaction?(resource)
         end) do
      raise ArgumentError,
            "storage transaction must own the outer transaction on transactional resources"
    end

    Process.put(@key, %{rollback: [], commit: []})

    try do
      # Establish commit before any notifier may raise. Never mistake a
      # post-commit notification failure for a database rollback.
      case Ash.transact(resources, callback, Keyword.put(opts, :return_notifications?, true)) do
        {:ok, value, notifications} ->
          state = Process.delete(@key)
          failures = PurgeFilesAfterTransaction.purge_now(state.commit)

          result =
            if opts[:return_notifications?] do
              {:ok, value, notifications}
            else
              case Ash.Notifier.notify(notifications) do
                [] ->
                  :ok

                remaining ->
                  Logger.warning(
                    "Storage transaction committed with #{length(remaining)} undelivered notifications"
                  )
              end

              {:ok, value}
            end

          if failures == [],
            do: result,
            else: {:error, {:storage_transaction_committed_cleanup_failed, failures}}

        {:error, _} = error ->
          cleanup_rollback(Process.delete(@key))
          error
      end
    catch
      kind, reason ->
        # The state was removed on commit, before cleanup or notification.
        cleanup_rollback(Process.delete(@key))
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      Process.delete(@key)
    end
  end

  def defer(kind, files) when kind in [:rollback, :commit] do
    case Process.get(@key) do
      nil ->
        false

      state ->
        Process.put(@key, Map.update!(state, kind, &Enum.uniq(&1 ++ files)))
        true
    end
  end

  defp cleanup_rollback(nil), do: :ok

  defp cleanup_rollback(state) do
    case PurgeFilesAfterTransaction.purge_now(state.rollback) do
      [] ->
        :ok

      failures ->
        Logger.error(
          "Storage outer transaction rolled back but uploaded object cleanup failed; reconciliation required: #{inspect(failures)}"
        )
    end
  end
end
