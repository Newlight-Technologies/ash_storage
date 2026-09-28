defmodule AshStorage.ChildContext do
  @moduledoc false

  require Ash.Query

  @doc """
  Converts an Ash callback context to options for a storage-owned child action.

  Ash's scope conversion carries the normalized actor, tenant, authorization,
  tracer, and shared context. The only private parent context intentionally
  inherited by storage children is AshOban's interaction marker. Other private
  keys and parent query/data-layer context must not cross this ownership edge.
  """
  def to_opts(context) do
    context
    |> Ash.Scope.to_opts()
    |> with_oban_marker(get_in(context.source_context, [:private, :ash_oban?]))
  end

  @doc "Narrows operation options before an internal child read."
  def narrow_opts(opts) do
    scope_opts =
      case Keyword.fetch(opts, :scope) do
        {:ok, scope} -> Ash.Scope.to_opts(scope)
        :error -> []
      end

    context = Keyword.get(opts, :context) || %{}
    scope_context = Keyword.get(scope_opts, :context) || %{}

    shared =
      Ash.Helpers.deep_merge_maps(
        Map.get(scope_context, :shared, %{}),
        Map.get(context, :shared, %{})
      )

    scope_opts
    |> Keyword.merge(Keyword.take(opts, [:actor, :tenant, :authorize?, :tracer]))
    |> Keyword.put(:context, %{shared: shared})
    |> with_oban_marker(get_in(context, [:private, :ash_oban?]))
  end

  @doc "Reads storage attachment rows and their blobs under the same child context."
  def read_attachments(attachment_resource, blob_resource, filter, opts) do
    attachment_resource
    |> Ash.Query.for_read(:read, %{}, opts)
    |> Ash.Query.filter(^filter)
    |> Ash.Query.load(blob: Ash.Query.for_read(blob_resource, :read, %{}, opts))
    |> Ash.read(Keyword.put(opts, :authorize_with, :error))
    |> ensure_loaded_blobs()
  end

  defp ensure_loaded_blobs({:ok, attachments} = result) do
    if Enum.all?(attachments, &match?(%{id: _}, &1.blob)) do
      result
    else
      {:error, :blob_not_found}
    end
  end

  defp ensure_loaded_blobs(error), do: error

  defp with_oban_marker(opts, true) do
    Keyword.update(opts, :context, %{private: %{ash_oban?: true}}, fn context ->
      Map.put(context, :private, %{ash_oban?: true})
    end)
  end

  defp with_oban_marker(opts, _), do: opts
end
