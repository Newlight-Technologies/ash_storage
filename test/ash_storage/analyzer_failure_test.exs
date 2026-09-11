defmodule AshStorage.AnalyzerFailureTest do
  use ExUnit.Case, async: true

  alias AshStorage.Analyzer.Failure

  test "static legacy errors remain actionable and terminal" do
    assert Failure.to_map(:analysis_failed) ==
             %{"code" => "analysis_failed", "retryable" => false}
  end

  test "explicit transient errors preserve retry classification" do
    assert Failure.to_map(%Failure{code: :scanner_unavailable, retryable?: true}) ==
             %{"code" => "scanner_unavailable", "retryable" => true}
  end

  test "arbitrary error terms never expose file content or local paths" do
    for reason <- [
          "private document text",
          {:error, "/private/source.pdf"},
          %{secret: "data"},
          nil,
          false,
          %Failure{code: nil, retryable?: true}
        ] do
      assert Failure.to_map(reason) == %{"code" => "analyzer_failed", "retryable" => false}
    end
  end
end
