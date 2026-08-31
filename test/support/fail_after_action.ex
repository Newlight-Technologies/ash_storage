defmodule AshStorage.Test.FailAfterAction do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, _record ->
      {:error, "forced rollback after storage lifecycle hooks"}
    end)
  end
end
