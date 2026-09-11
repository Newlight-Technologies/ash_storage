defmodule AshStorage.Test.AnalyzerActorPersister do
  @moduledoc false
  use AshOban.ActorPersister

  @impl true
  def store(%{restricted?: restricted?, role: role}) do
    %{"restricted" => restricted?, "role" => Atom.to_string(role)}
  end

  @impl true
  def lookup(nil), do: {:ok, nil}

  def lookup(%{"restricted" => restricted?, "role" => "viewer"}) do
    {:ok, %{restricted?: restricted?, role: :viewer}}
  end

  def lookup(%{"restricted" => restricted?, "role" => "editor"}) do
    {:ok, %{restricted?: restricted?, role: :editor}}
  end
end
