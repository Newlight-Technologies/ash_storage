defmodule AshStorage.AnalyzerObanTest do
  use AshStorage.RepoCase, async: false
  use Oban.Testing, repo: AshStorage.TestRepo

  @moduletag :oban

  alias AshStorage.Operations
  alias AshStorage.Test.{PgBlob, PgPost}

  setup do
    AshStorage.Service.Test.reset!()
    :ok
  end

  defp create_post!(title \\ "test post") do
    PgPost
    |> Ash.Changeset.for_create(:create, %{title: title})
    |> Ash.create!()
  end

  defp attach_with_analyzers!(post, content, opts) do
    {:ok, %{blob: blob}} = Operations.attach(post, :cover_image, content, opts)

    # Simulate what the attach flow does when analyzers are configured:
    # set the analyzers map with pending entries
    analyzers_map = Keyword.fetch!(opts, :analyzers_map)

    {:ok, blob} =
      Ash.update(blob, %{analyzers: analyzers_map}, action: :update_metadata)

    blob
  end

  describe "run_analyzer/3 on Postgres" do
    test "missing source records failure and recovery analyzes the restored original" do
      post = create_post!()
      analyzer = AshStorage.Test.TestAnalyzer
      key = to_string(analyzer)

      blob =
        attach_with_analyzers!(post, "original evidence",
          filename: "source.txt",
          content_type: "text/plain",
          analyzers_map: %{key => %{"status" => "pending", "opts" => %{}}}
        )

      service_context = AshStorage.Service.Context.new([])
      :ok = AshStorage.Service.Test.delete(blob.key, service_context)

      assert {:ok, failed} = Operations.run_analyzer(blob, analyzer)
      persisted = Ash.get!(PgBlob, blob.id)
      assert persisted.analyzers[key]["status"] == "error"

      assert persisted.analyzers[key]["failure"] ==
               %{"code" => "analyzer_download_failed", "retryable" => true}

      refute Map.has_key?(persisted.metadata, "line_count")

      :ok = AshStorage.Service.Test.upload(blob.key, "original evidence", service_context)
      assert {:ok, recovered} = Operations.run_analyzer(failed, analyzer)
      assert recovered.id == blob.id
      assert recovered.analyzers[key]["status"] == "complete"
      assert recovered.analyzers[key]["failure"] == nil
      assert recovered.metadata["line_count"] == 1
    end

    test "explicit retry clears previous failure only after a successful analysis" do
      post = create_post!()
      analyzer_key = to_string(AshStorage.Test.RecoveringAnalyzer)

      blob =
        attach_with_analyzers!(post, "evidence",
          filename: "source.txt",
          content_type: "text/plain",
          analyzers_map: %{
            analyzer_key => %{
              "status" => "pending",
              "opts" => %{"test_key" => Ash.UUID.generate()}
            }
          }
        )

      assert {:ok, failed} = Operations.run_analyzer(blob, AshStorage.Test.RecoveringAnalyzer)
      assert failed.analyzers[analyzer_key]["status"] == "error"

      assert failed.analyzers[analyzer_key]["failure"] ==
               %{"code" => "scanner_unavailable", "retryable" => true}

      refute Map.has_key?(failed.metadata, "recovered_byte_count")

      assert {:ok, recovered} =
               Operations.run_analyzer(failed, AshStorage.Test.RecoveringAnalyzer)

      persisted = Ash.get!(PgBlob, recovered.id)
      assert persisted.analyzers[analyzer_key]["status"] == "complete"
      assert persisted.analyzers[analyzer_key]["failure"] == nil
      assert persisted.metadata["recovered_byte_count"] == 8
    end

    test "atomically completes analysis and merges metadata" do
      post = create_post!()

      blob =
        attach_with_analyzers!(post, "hello\nworld\n",
          filename: "hello.txt",
          content_type: "text/plain",
          analyzers_map: %{
            to_string(AshStorage.Test.TestAnalyzer) => %{
              "status" => "pending",
              "opts" => %{}
            }
          }
        )

      assert blob.analyzers[to_string(AshStorage.Test.TestAnalyzer)]["status"] == "pending"

      {:ok, updated_blob} =
        Operations.run_analyzer(blob, AshStorage.Test.TestAnalyzer)

      assert updated_blob.analyzers[to_string(AshStorage.Test.TestAnalyzer)]["status"] ==
               "complete"

      assert updated_blob.metadata["line_count"] == 3
    end

    test "atomically marks analyzer as error on failure" do
      post = create_post!()

      blob =
        attach_with_analyzers!(post, "some data",
          filename: "file.txt",
          content_type: "text/plain",
          analyzers_map: %{
            to_string(AshStorage.Test.FailingAnalyzer) => %{
              "status" => "pending",
              "opts" => %{}
            }
          }
        )

      {:ok, updated_blob} =
        Operations.run_analyzer(blob, AshStorage.Test.FailingAnalyzer)

      assert updated_blob.analyzers[to_string(AshStorage.Test.FailingAnalyzer)]["status"] ==
               "error"

      assert updated_blob.analyzers[to_string(AshStorage.Test.FailingAnalyzer)]["failure"] ==
               %{"code" => "analysis_failed", "retryable" => false}
    end

    test "marks analyzer as skipped when content type not accepted" do
      post = create_post!()

      blob =
        attach_with_analyzers!(post, "not an image",
          filename: "file.txt",
          content_type: "text/plain",
          analyzers_map: %{
            to_string(AshStorage.Test.ImageAnalyzer) => %{
              "status" => "pending",
              "opts" => %{}
            }
          }
        )

      {:ok, updated_blob} =
        Operations.run_analyzer(blob, AshStorage.Test.ImageAnalyzer)

      assert updated_blob.analyzers[to_string(AshStorage.Test.ImageAnalyzer)]["status"] ==
               "skipped"
    end

    test "passes stored opts to analyzer" do
      post = create_post!()

      blob =
        attach_with_analyzers!(post, "hello world",
          filename: "hello.txt",
          content_type: "text/plain",
          analyzers_map: %{
            to_string(AshStorage.Test.TestAnalyzer) => %{
              "status" => "pending",
              "opts" => %{"include_word_count" => true}
            }
          }
        )

      {:ok, updated_blob} =
        Operations.run_analyzer(blob, AshStorage.Test.TestAnalyzer)

      assert updated_blob.metadata["word_count"] == 2
      assert updated_blob.metadata["line_count"] == 1
    end

    test "concurrent analyzers don't clobber each other" do
      post = create_post!()

      blob =
        attach_with_analyzers!(post, "hello world",
          filename: "hello.txt",
          content_type: "text/plain",
          analyzers_map: %{
            to_string(AshStorage.Test.TestAnalyzer) => %{
              "status" => "pending",
              "opts" => %{}
            },
            to_string(AshStorage.Test.FailingAnalyzer) => %{
              "status" => "pending",
              "opts" => %{}
            }
          }
        )

      # Run both analyzers sequentially (simulating concurrent AshOban jobs)
      {:ok, _} = Operations.run_analyzer(blob, AshStorage.Test.TestAnalyzer)
      {:ok, _} = Operations.run_analyzer(blob, AshStorage.Test.FailingAnalyzer)

      # Re-fetch to see the combined result
      final_blob = Ash.get!(PgBlob, blob.id)

      assert final_blob.analyzers[to_string(AshStorage.Test.TestAnalyzer)]["status"] ==
               "complete"

      assert final_blob.analyzers[to_string(AshStorage.Test.FailingAnalyzer)]["status"] ==
               "error"

      assert final_blob.metadata["line_count"] == 1
    end

    test "returns error for unconfigured analyzer" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        Operations.attach(post, :cover_image, "data", filename: "f.txt")

      assert {:error, :analyzer_not_configured} =
               Operations.run_analyzer(blob, AshStorage.Test.TestAnalyzer)
    end

    test "preserves existing metadata when merging" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        Operations.attach(post, :cover_image, "hello",
          filename: "hello.txt",
          content_type: "text/plain",
          metadata: %{"custom" => "value"}
        )

      # Add analyzers map
      {:ok, blob} =
        Ash.update(
          blob,
          %{
            analyzers: %{
              to_string(AshStorage.Test.TestAnalyzer) => %{
                "status" => "pending",
                "opts" => %{}
              }
            }
          },
          action: :update_metadata
        )

      {:ok, updated_blob} =
        Operations.run_analyzer(blob, AshStorage.Test.TestAnalyzer)

      assert updated_blob.metadata["custom"] == "value"
      assert updated_blob.metadata["line_count"] == 1
    end
  end

  describe "run_pending_analyzers action" do
    test "runs all pending analyzers for a blob" do
      post = create_post!()

      blob =
        attach_with_analyzers!(post, "hello world",
          filename: "hello.txt",
          content_type: "text/plain",
          analyzers_map: %{
            to_string(AshStorage.Test.TestAnalyzer) => %{
              "status" => "pending",
              "opts" => %{}
            },
            to_string(AshStorage.Test.FailingAnalyzer) => %{
              "status" => "pending",
              "opts" => %{}
            }
          }
        )

      {:ok, updated_blob} = Ash.update(blob, %{}, action: :run_pending_analyzers)

      assert updated_blob.analyzers[to_string(AshStorage.Test.TestAnalyzer)]["status"] ==
               "complete"

      assert updated_blob.analyzers[to_string(AshStorage.Test.FailingAnalyzer)]["status"] ==
               "error"

      assert updated_blob.metadata["line_count"] == 1
    end

    test "skips analyzers that don't accept the content type" do
      post = create_post!()

      blob =
        attach_with_analyzers!(post, "not an image",
          filename: "file.txt",
          content_type: "text/plain",
          analyzers_map: %{
            to_string(AshStorage.Test.ImageAnalyzer) => %{
              "status" => "pending",
              "opts" => %{}
            }
          }
        )

      {:ok, updated_blob} = Ash.update(blob, %{}, action: :run_pending_analyzers)

      assert updated_blob.analyzers[to_string(AshStorage.Test.ImageAnalyzer)]["status"] ==
               "skipped"
    end

    test "does nothing when no pending analyzers" do
      post = create_post!()

      blob =
        attach_with_analyzers!(post, "hello",
          filename: "hello.txt",
          content_type: "text/plain",
          analyzers_map: %{
            to_string(AshStorage.Test.TestAnalyzer) => %{
              "status" => "complete",
              "opts" => %{}
            }
          }
        )

      {:ok, updated_blob} = Ash.update(blob, %{}, action: :run_pending_analyzers)

      assert updated_blob.analyzers[to_string(AshStorage.Test.TestAnalyzer)]["status"] ==
               "complete"
    end
  end

  describe "pending_analyzers flag" do
    test "pending_analyzers is set to true when oban analyzers are configured" do
      post = create_post!()

      blob =
        attach_with_analyzers!(post, "hello",
          filename: "hello.txt",
          content_type: "text/plain",
          analyzers_map: %{
            to_string(AshStorage.Test.TestAnalyzer) => %{
              "status" => "pending",
              "opts" => %{}
            }
          }
        )

      {:ok, blob} =
        Ash.update(blob, %{pending_analyzers: true}, action: :update_metadata)

      assert blob.pending_analyzers == true
    end

    test "pending_analyzers clears when last analyzer completes" do
      post = create_post!()

      blob =
        attach_with_analyzers!(post, "hello",
          filename: "hello.txt",
          content_type: "text/plain",
          analyzers_map: %{
            to_string(AshStorage.Test.TestAnalyzer) => %{
              "status" => "pending",
              "opts" => %{}
            }
          }
        )

      {:ok, blob} =
        Ash.update(blob, %{pending_analyzers: true}, action: :update_metadata)

      assert blob.pending_analyzers == true

      # Run the analyzer — it's the only one, so the flag should clear
      {:ok, blob} = Operations.run_analyzer(blob, AshStorage.Test.TestAnalyzer)

      # Re-fetch to get the flag from DB
      blob = Ash.get!(PgBlob, blob.id)
      assert blob.pending_analyzers == false
    end

    test "pending_analyzers stays true while analyzers remain pending" do
      post = create_post!()

      blob =
        attach_with_analyzers!(post, "hello",
          filename: "hello.txt",
          content_type: "text/plain",
          analyzers_map: %{
            to_string(AshStorage.Test.TestAnalyzer) => %{
              "status" => "pending",
              "opts" => %{}
            },
            to_string(AshStorage.Test.FailingAnalyzer) => %{
              "status" => "pending",
              "opts" => %{}
            }
          }
        )

      {:ok, blob} =
        Ash.update(blob, %{pending_analyzers: true}, action: :update_metadata)

      # Run only TestAnalyzer — FailingAnalyzer is still pending
      {:ok, _blob} = Operations.run_analyzer(blob, AshStorage.Test.TestAnalyzer)

      blob = Ash.get!(PgBlob, blob.id)
      assert blob.pending_analyzers == true

      # Now run FailingAnalyzer — it errors, but both are now non-pending
      {:ok, _blob} = Operations.run_analyzer(blob, AshStorage.Test.FailingAnalyzer)

      blob = Ash.get!(PgBlob, blob.id)
      assert blob.pending_analyzers == false
    end
  end

  describe "complete_analysis action atomic fragments" do
    test "jsonb_set atomically updates analyzer status" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        Operations.attach(post, :cover_image, "data",
          filename: "f.txt",
          content_type: "text/plain"
        )

      # Set initial analyzers map
      {:ok, blob} =
        Ash.update(
          blob,
          %{
            analyzers: %{
              "analyzer_a" => %{"status" => "pending", "opts" => %{}},
              "analyzer_b" => %{"status" => "pending", "opts" => %{}}
            }
          },
          action: :update_metadata
        )

      # Complete analyzer_a
      {:ok, blob} =
        Ash.update(
          blob,
          %{analyzer_key: "analyzer_a", status: "complete", metadata_to_merge: %{"a" => 1}},
          action: :complete_analysis
        )

      assert blob.analyzers["analyzer_a"]["status"] == "complete"
      # analyzer_b should still be pending
      assert blob.analyzers["analyzer_b"]["status"] == "pending"
      assert blob.metadata["a"] == 1

      # Complete analyzer_b
      {:ok, blob} =
        Ash.update(
          blob,
          %{analyzer_key: "analyzer_b", status: "complete", metadata_to_merge: %{"b" => 2}},
          action: :complete_analysis
        )

      assert blob.analyzers["analyzer_b"]["status"] == "complete"
      # analyzer_a result should still be there
      assert blob.analyzers["analyzer_a"]["status"] == "complete"
      assert blob.metadata["a"] == 1
      assert blob.metadata["b"] == 2
    end
  end
end
