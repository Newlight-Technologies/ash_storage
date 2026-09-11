defmodule AshStorage.Analyzer.Failure do
  @moduledoc """
  A safe, machine-readable analyzer failure.

  `code` must be a static atom, not document text or scanner output. A retryable
  failure indicates that a later attempt may succeed; it never indicates that
  the file is safe. Raw exceptions and arbitrary error terms are not persisted.
  """
  @enforce_keys [:code]
  defstruct [:code, retryable?: false]

  @type t :: %__MODULE__{code: atom(), retryable?: boolean()}

  def to_map(%__MODULE__{code: code, retryable?: retryable?})
      when is_atom(code) and code not in [nil, true, false] do
    %{"code" => Atom.to_string(code), "retryable" => retryable? == true}
  end

  def to_map(code) when is_atom(code) and code not in [nil, true, false] do
    %{"code" => Atom.to_string(code), "retryable" => false}
  end

  def to_map(_reason), do: %{"code" => "analyzer_failed", "retryable" => false}
end
