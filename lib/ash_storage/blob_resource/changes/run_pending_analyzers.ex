defmodule AshStorage.BlobResource.Changes.RunPendingAnalyzers do
  @moduledoc """
  A change that runs all pending analyzers for a blob.

  Used by the `:run_pending_analyzers` action, typically triggered by AshOban.
  Iterates through the blob's analyzers map, finds any with `"status" => "pending"`,
  and runs each one via `AshStorage.Operations.run_analyzer/2`.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    context_opts = Ash.Context.to_opts(context)

    Ash.Changeset.after_transaction(changeset, fn
      changeset, {:ok, blob} ->
        job =
          get_in(changeset.context, [:ash_oban, :job]) ||
            get_in(changeset.context, [:shared, :ash_oban, :job])

        retry? = match?(%{attempt: attempt, max_attempts: maximum} when attempt < maximum, job)

        analyzers = blob.analyzers || %{}

        pending =
          Enum.filter(analyzers, fn {_mod, info} ->
            info["status"] == "pending"
          end)

        result =
          Enum.reduce_while(pending, {:ok, blob}, fn {analyzer_mod, _info}, {:ok, blob} ->
            # sobelow_skip ["DOS.BinToAtom"]
            module = String.to_existing_atom(analyzer_mod)

            case AshStorage.Operations.run_analyzer(
                   blob,
                   module,
                   context_opts
                   |> Keyword.put(:tenant, changeset.tenant)
                   |> Keyword.put(:analyzer_retry?, retry?)
                 ) do
              {:ok, blob} -> {:cont, {:ok, blob}}
              {:error, error} -> {:halt, {:error, error}}
            end
          end)

        case result do
          {:ok, updated} when not is_nil(job) ->
            if Enum.any?(pending, fn {key, _info} ->
                 get_in(updated.analyzers, [key, "failure", "retryable"]) == true
               end) do
              {:error, "analyzer_retry_required"}
            else
              {:ok, updated}
            end

          result ->
            result
        end

      _changeset, {:error, _} = error ->
        error
    end)
  end
end
