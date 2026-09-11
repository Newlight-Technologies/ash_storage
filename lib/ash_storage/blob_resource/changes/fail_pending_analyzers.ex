defmodule AshStorage.BlobResource.Changes.FailPendingAnalyzers do
  @moduledoc """
  Records exhausted background analysis without persisting exception contents.

  Use as the analyzer trigger's on_error action. Completed analyzer entries and
  their metadata remain intact; only unfinished entries are marked as failed.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    opts = Ash.Context.to_opts(context)

    Ash.Changeset.after_action(changeset, fn _changeset, blob ->
      Enum.reduce_while(blob.analyzers || %{}, {:ok, blob}, fn
        {key, %{"status" => "pending"} = entry}, {:ok, current} ->
          failure =
            (entry["failure"] || %{"code" => "analyzer_job_exhausted", "retryable" => false})
            |> Map.put("exhausted", true)

          case Ash.update(
                 current,
                 %{analyzer_key: key, status: "error", failure: failure},
                 Keyword.put(opts, :action, :complete_analysis)
               ) do
            {:ok, updated} -> {:cont, {:ok, updated}}
            {:error, error} -> {:halt, {:error, error}}
          end

        _, result ->
          {:cont, result}
      end)
    end)
  end
end
