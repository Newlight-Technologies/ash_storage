defmodule AshStorage.Test.TransactionTestNotifier do
  use Ash.Notifier

  @impl true
  def notify(_notification) do
    if Process.get({__MODULE__, :raise?}), do: raise("post-commit notification failed")
    :ok
  end
end
